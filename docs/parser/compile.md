# Compiler 仕様 — AST → Bytecode

Compiler (`compile_stmt` / `compile_expr` 系) は ASTNode を受け取り、`@bytecode`
配列に opcode と SLEB128 オペランドを push する。1 パスで動作するため、
ジャンプ先の patch up や前方参照不可といった制約がある。

各 opcode の意味は [bytecode/opcodes.md](../bytecode/opcodes.md)、値表現は
[bytecode/overview.md](../bytecode/overview.md) を参照。

## 静的契約

`compile_stmt` / `compile_expr` のいずれも、終了時にスタックに **値を 1 つだけ
残す** ことを契約とする。文として消費するときは外側で `POP` を 1 つ追加する。
これにより `:seq` チェーンや `if`/`while` 末尾で値が常に 1 つ残ることが保証される。

## エンコード基本単位

### SLEB128 オペランド

可変長符号付き整数。`encode_signed` / `decode_signed` で出し入れする。
`@bytecode` に直接 byte を push する形でエンコードする。

### 3 バイト固定 SLEB128 (jump offset)

`JUMP` / `JUMP_IF_FALSE` / `PUSH_HANDLER` の jump offset は **3 バイト固定**。
1 パスのため emit 時点では飛び先 PC が未定なので、3 バイトの placeholder を
書いておき、飛び先確定時に書き直す (patch up)。範囲は ±1M バイト。

## compile_stmt の分岐 (主要文)

### `:puts_stmt`

```
<compile expr>
PUTS                         ; Op::PUTS は値を出力して NIL を push
```

文として直後に外側 `POP` で nil を捨てる。

### `:if_expr`

```
<compile cond>
JUMP_IF_FALSE else_label     ; 3-byte placeholder
  <compile then>
  JUMP end_label             ; 3-byte placeholder
else_label:
  <compile else>             ; 省略時は PUSH_NIL
end_label:
```

then/else 双方が必ず 1 値残すため、合流後のスタック高さは一致する。

### `:while_stmt`

```
loop_start:                  ; @loop_start_pcs.push(loop_start)
<compile cond>
JUMP_IF_FALSE loop_end
  <compile body>
  POP                        ; body の値を捨てる
  JUMP loop_start
loop_end:                    ; @break_patch_pcs[start..] を全て loop_end へ patch up
PUSH_NIL                     ; while 全体の値
```

`loop do ... end` (Stage 4b) は parser が cond=`:bool_lit(true)` の `:while_stmt`
として AST 化するため、compiler 側の特別扱いは不要。

### `:break_stmt` / `:next_stmt` (Stage 4b)

`break` / `next` は **コンパイル時に既存の `JUMP` opcode に展開** される。新 opcode
は不要。3 つの並列 IntArray でジャンプ解決を管理する:

| 並列 IntArray | 役割 |
|---|---|
| `@loop_start_pcs` | loop / while の cond 再評価位置スタック (`next` の jump target) |
| `@break_patch_starts` | 各 loop ごとの `@break_patch_pcs` 開始 idx |
| `@break_patch_pcs` | 全 loop の `break` 用 placeholder PC を flat に並べる |
| `@loop_scope_barriers` | method / block 境界での「可視 loop 深度」barrier |

- `compile_while` 進入時: `@loop_start_pcs.push(loop_start)`、`@break_patch_starts.push(@break_patch_pcs.length)`
- `compile_break`: `JUMP` を emit して placeholder PC を `@break_patch_pcs` に積む
- `compile_next`: `JUMP` を emit して即 `loop_start_pcs.last` に patch
- `compile_while` 退出時: `@break_patch_starts.pop` で得た開始 idx 以降の placeholder
  をすべて `loop_end` (= 現在 PC) へ patch up

ブロック (`do |x| ... end`) と method 境界では `@loop_scope_barriers` に
現在の `@loop_start_pcs.length` を積み、内側からは外側 loop が「見えない」状態にする。
これによりブロック内 / メソッド内 loop の外側で `break` / `next` を書くと compile error
になる。

`break` / `next` を含む method は HIR builder の不変条件 (各 stmt が 1 値残す) を
壊すため `mark_current_method_jit_unsafe` で JIT 経路から除外する。

### `:method_def`

```
JUMP skip_body               ; トップレベル制御フローから skip
method_pc:                   ; @method_pcs[m_idx] に記録
  <compile body>
  RETURN                     ; 防御的 (戻り値が省略されたとき)
skip_body:
PUSH_NIL                     ; def 文自体の値
```

method 表 (`@method_*` 5 並列 IntArray) に entry を追加。`@method_arities[m_idx]` =
パラメータ数、`@method_local_counts[m_idx]` = body コンパイル後に確定したスコープ
ローカル合計数。

### `:class_def`

class 表 (`@class_*` 並列 IntArray) に entry 追加 → body 内の `:method_def` を
ループしてコンパイル (`@method_class_idx[m_idx] = class_idx` をセット)。
継承時は親が先に登録されている必要がある (1 パス制約)。

### `:return_stmt`

```
<compile expr>               ; 省略時は PUSH_NIL 相当
RETURN
```

### `:seq`

```
<compile head>
POP                          ; head の値を捨てる
<compile tail>               ; こちらが値を残す
```

## compile_expr の分岐 (主要式)

### リテラル

| Kind | emit |
|---|---|
| `:int_lit` | `PUSH_INT n` |
| `:str_lit` | `PUSH_STR strlit_idx` |
| `:bool_lit` | `PUSH_TRUE` / `PUSH_FALSE` |
| `:nil_lit` | `PUSH_NIL` |
| `:self_lit` | `LOAD_SELF` |

### `:var_ref` / `:assign`

```
:var_ref       → LOAD_LOCAL slot
:assign        → <compile rhs>; STORE_LOCAL slot   (STORE_LOCAL は pop しない)
```

slot は `find_local(packed)` で解決。未宣言なら `declare_local` で並列 IntArray
(`@local_starts/_lens`) に append し新 slot を返す。

### `:ivar_ref` / `:ivar_assign`

```
:ivar_ref      → LOAD_IVAR ivar_slot
:ivar_assign   → <compile rhs>; STORE_IVAR ivar_slot
```

ivar slot は `find_or_declare_ivar_slot(class_idx, packed)` で解決。
継承クラスは親 chain を walk して既存名を探す (Stage 3d.4)。

### `:bin_op`

```
<compile lhs>
<compile rhs>
<op (ADD/SUB/MUL/DIV/MOD/LSHIFT/EQ/LT/GT/LE/GE)>
```

`:add` の lhs が `:int_lit(0)` の特殊化 (単項マイナス) は parser で別経路。

### `:method_call` (暗黙 self)

```
<for each arg>: <compile arg>
CALL m_idx                   ; ブロックなし
or
CALL_WITH_BLOCK m_idx, block_pc, block_arity   ; ブロックあり
```

ブロック付きの場合は事前に `compile_inline_block` でブロック本体を
**skip-jump パターン**で `@bytecode` 末尾に配置し、その先頭 PC を operand に渡す。

### `:method_call_on` (`obj.foo(args)`)

通常パスは:

```
<compile receiver>
<for each arg>: <compile arg>
CALL_METHOD name_packed, argc
```

block 付きは `CALL_METHOD_WITH_BLOCK`。

**特殊認識**: receiver が `:var_ref` でクラステーブルにあり、method 名が `new` の
ときは `compile_class_new` が `INSTANCE_NEW class_idx` (+ initialize 呼び出し)
に展開する (Stage 3d.1 / 3d.2)。

### `:array_lit`

```
<for each element>: <compile elem>
ARRAY_NEW size
```

### `:yield_expr`

```
<compile arg>                ; 省略時は省略
YIELD argc                   ; argc は 0 か 1
```

ブロックがない method で yield が実行されると VM が LocalJumpError を raise。
arity 不一致は Stage 3d.5 で緩和され、余剰は捨て不足は nil 埋め。

### `:super_call`

```
LOAD_SELF                    ; CALL_SUPER の receiver
<for each arg>: <compile arg>
or (bare super):
<for each param>: LOAD_LOCAL slot   ; 現メソッドのパラメータを転送
CALL_SUPER name_packed, argc
```

検索開始 class は `@cur_method_class_idx` の **親** から (= 自分自身は skip)。

### `:begin_rescue`

```
PUSH_HANDLER catch_pc        ; ハンドラスタックに登録
<compile body>
POP_HANDLER                  ; 正常終了パス
JUMP after_rescue
catch_pc:
  <rescue chain: CHECK_EXCEPTION_CLASS / LOAD_EXCEPTION / ... / CLEAR_EXCEPTION>
  RERAISE_OR_END             ; マッチしなければ外側へ伝播
after_rescue:
  <compile ensure body>      ; ensure 節 (あれば)
  RERAISE_OR_END              ; @exception が残っていれば再 unwind
```

詳細は `compile_begin_rescue` (interp.rb:1689) を参照。

### `:raise`

```
<compile exception expr>     ; "msg" なら StandardError.new("msg") に展開
RAISE
```

raise/begin を含む method は HIR/LIR 未対応のため
`mark_current_method_jit_unsafe` で JIT 走査から外す。

## ローカル変数とスコープ

### スコープ管理

- トップレベルとメソッド内は別の `@scope_base` で区切られる
- メソッド開始時に `@scope_base = @local_starts.length` を退避してから
  パラメータを `declare_local` で順に登録 → ローカルは slot 0 から arity-1
- メソッド終了時に `@scope_base` を復元、追加された local entry は破棄

### ブロックパラメータ

`do |x| body end` の `x` は **enclosing method scope に名前付き local として宣言**
される (Ruby 1.9+ の block-local とは divergence)。これにより block 内から
caller の変数を自然に read/write できる (closure 相当)。

### 匿名 local slot

`each` 等の inline 展開で受信者退避とカウンタに使う。`declare_anonymous_local`
が `@local_lens.push(0)` (= sentinel) で追加する。`find_in_table` 側で
`pkg_len == 0` の早期 return によりユーザ識別子と衝突しない。

## 1 パス制約

- **相互再帰不可**: 自己再帰は OK だが `def f; g; end; def g; f; end` は不可
- **継承の親宣言順**: `class B \< A` は `class A` の後でなければならない
  (循環参照は親未定義エラーで自然に防止)
- **前方参照禁止**: コンパイル時に `find_method` で見つからないものは
  即時エラー
- **method 本体内 def 禁止**: `@in_method` フラグでチェック (compile_method_def)

## JIT との連携

ホットメソッドは `@bytecode` 上の (begin_pc, end_pc) 区間が `build_hir` の対象になる。
そのため compile 時に各 method の bytecode 範囲を `@method_body_ends` に記録しておく
(JIT-2 で導入)。

例外処理・class メソッド呼び出し等は HIR で扱わない。該当機能を使う method には
`mark_current_method_jit_unsafe` で `@jit_call_counts[m_idx] = JIT_HOT_THRESHOLD`
をセットしてホット検出から外す。
