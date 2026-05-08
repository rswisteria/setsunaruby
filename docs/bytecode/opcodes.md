# Bytecode Opcode 仕様

`lib/setsunaruby/opcodes.rb` の `module Op` で定義された全 opcode の仕様。
スタック効果・オペランド・実行詳細を記述する。値表現と VM 状態は
[overview.md](overview.md) を参照。

## 表記

- **Stack**: `[..., a, b]` → `[..., r]` の形で「実行前のスタック末尾」と
  「実行後のスタック末尾」を表す。`...` は変化しない部分
- **Operand**: opcode 直後にエンコードされる値。SLEB128 (可変長) と
  3byte SLEB (固定長) の 2 種類がある
- **Stage**: 導入された Stage

---

## 値プッシュ

### `PUSH_INT` (0x01)

- Operand: SLEB128 整数値
- Stack: `[...]` → `[..., box_int(n)]`
- Stage: 0
- 整数値を `(n \<\< 1) | 1` にタグ付けして push。SLEB128 のため負数も自然に扱える

### `PUSH_TRUE` (0x02) / `PUSH_FALSE` (0x03) / `PUSH_NIL` (0x04)

- Operand: なし
- Stack: `[...]` → `[..., TRUE_VAL]` / `[..., FALSE_VAL]` / `[..., NIL_VAL]`
- Stage: 0
- 固定 obj_id を push

---

## スタック・ローカル制御

### `POP` (0x05)

- Operand: なし
- Stack: `[..., a]` → `[...]`
- Stage: 1

### `STORE_LOCAL` (0x06)

- Operand: SLEB128 idx
- Stack: `[..., a]` → `[..., a]` (**pop しない**)
- Stage: 1
- `@locals[@cur_base + idx]` に top を書く。連続代入 `x = (y = 1) + 1` を
  自然に書けるため pop しない設計

### `LOAD_LOCAL` (0x07)

- Operand: SLEB128 idx
- Stack: `[...]` → `[..., @locals[@cur_base + idx]]`
- Stage: 1

### `JUMP` (0x08)

- Operand: 3-byte 固定 SLEB128 offset
- Stack: 変化なし
- Stage: 1
- `@pc += offset`。1 パス compile のため固定 3 バイト

### `JUMP_IF_FALSE` (0x09)

- Operand: 3-byte 固定 SLEB128 offset
- Stack: `[..., cond]` → `[...]`
- Stage: 1
- top を pop し、`cond == NIL_VAL || cond == FALSE_VAL` なら `@pc += offset`

---

## 算術 (二項)

### `ADD` (0x10) / `SUB` (0x11) / `MUL` (0x12) / `DIV` (0x13) / `MOD` (0x14)

- Operand: なし
- Stack: `[..., a, b]` → `[..., r]`
- Stage: 0 / Stage 3a で `ADD` を文字列連結に多相化

両辺 Fixnum なら算術。`ADD` のみ両辺 String なら新ヒープスロットに連結結果を
確保して push。型不一致は TypeError を raise。`DIV` / `MOD` は b == 0 で
ZeroDivisionError。

---

## 比較

### `EQ` (0x20) / `LT` (0x21) / `GT` (0x22) / `LE` (0x23) / `GE` (0x24)

- Operand: なし
- Stack: `[..., a, b]` → `[..., bool]`
- Stage: 0
- `EQ` のみ両辺 String を値比較に多相化 (Stage 3a)。それ以外は obj_id 同値比較
- 順序比較は両辺 Fixnum 必須

---

## I/O

### `PUTS` (0x30)

- Operand: なし
- Stack: `[..., v]` → `[..., NIL_VAL]`
- Stage: 0
- v を `to_puts_string` で文字列化して stdout + 改行。Ruby の `puts` セマンティクス
  (配列なら要素別行 + ネスト再帰展開)。`POP` との整合のため NIL_VAL を push する

---

## メソッド呼び出し

### `CALL` (0x40)

- Operand: SLEB128 method_idx
- Stack: `[..., arg_1, ..., arg_n]` → `[..., return_value]`
- Stage: 2

実行詳細:

1. `argc = @method_arities[m_idx]`、`local_count = @method_local_counts[m_idx]`
2. `@cfp_pcs.push(@pc)`、`@cfp_bases.push(@cur_base)`、その他 cfp_* を退避
3. `@cur_base = @locals.length`
4. `@locals` を NIL_VAL で local_count 個拡張、末尾 argc 個を引数で上書き
5. 値スタックから引数を pop (ローカル領域に移ったので)
6. `@pc = @method_pcs[m_idx]`

### `RETURN` (0x41)

- Operand: なし
- Stack: `[..., return_value]` → `[..., return_value]` (フレーム pop 後)
- Stage: 2

実行詳細:

1. return_value = top (peek)
2. `@locals` を `@cur_base` まで縮小
3. `@cur_base` / `@pc` / `@cur_self` 等を `@cfp_*` から restore
4. return_value はスタック top に残る (peek だったため)

---

## 文字列 (Stage 3a)

### `PUSH_STR` (0x42)

- Operand: SLEB128 strlit_idx
- Stack: `[...]` → `[..., heap_ref]`
- Stage: 3a
- `@strlit_starts[idx]` / `@strlit_lens[idx]` のバイト列を `@str_pool` 末尾に
  コピーして新ヒープスロット (kind=1) を確保。`(new_idx \<\< 3) | 0b110` を push
- リテラル独立性のため毎回新ヒープスロットを確保する

### `LSHIFT` (0x43)

- Operand: なし
- Stack: `[..., lhs, rhs]` → `[..., lhs]`
- Stage: 3a (String) / 3b (Array へ多相化)
- 多相 dispatch (heap_kind による):
  - **String × String**: lhs slot を relocate-and-grow で `(start, len)` を
    `(@str_pool.length - (len_l+len_r), len_l+len_r)` に書き換え。
    旧領域は abandon (no-GC)。同 obj_id 共有先からも更新が見える Ruby 互換動作
  - **Array × any**: `@heap_arr_pool` 末尾に rhs を push、`@heap_lens[lhs_idx] += 1`
- 戻り値は lhs (Ruby 互換)

---

## 配列 (Stage 3b)

### `ARRAY_NEW` (0x44)

- Operand: SLEB128 size
- Stack: `[..., e_0, ..., e_{size-1}]` → `[..., array_ref]`
- Stage: 3b
- size 個を `@heap_arr_pool` 末尾にコピーして新スロット (kind=2) を確保

### `ARRAY_GET` (0x45)

- Operand: なし
- Stack: `[..., arr, idx]` → `[..., arr[idx]]`
- Stage: 3b
- 範囲外 (idx \< 0 or idx \>= len) は NIL_VAL を push

### `ARRAY_SET` (0x46)

- Operand: なし
- Stack: `[..., arr, idx, val]` → `[..., val]`
- Stage: 3b
- 範囲外書き込みはエラー

### `ARRAY_LEN` (0x47)

- Operand: なし
- Stack: `[..., arr]` → `[..., box_int(len)]`
- Stage: 3b

---

## ブロックと yield (Stage 3c.2)

### `CALL_WITH_BLOCK` (0x48)

- Operand: SLEB128 method_idx, SLEB128 block_pc, SLEB128 block_arity
- Stack: `[..., arg_1, ..., arg_n]` → `[..., return_value]`
- Stage: 3c.2
- `CALL` と同じだが新フレームに block_pc / block_arity を紐付ける

### `YIELD` (0x49)

- Operand: SLEB128 argc
- Stack: `[..., arg_1, ..., arg_argc]` → `[..., block_return_value]`
- Stage: 3c.2

実行詳細:

1. `target_idx = @yield_target_idx.last` (lexical method の cfp idx)
2. block_pc \< 0 なら LocalJumpError
3. `@yield_pcs.push(@pc)`、`@yield_bases.push(@cur_base)` で復帰情報退避
4. `@cur_base = @cfp_bases[target_idx]` (caller's scope に切替)
5. `@pc = @cfp_block_pcs[target_idx]` (ブロック先頭へ)
6. arity 不一致は緩和: 余剰 args は捨て、不足分は NIL_VAL で埋める

### `BLOCK_RETURN` (0x4A)

- Operand: なし
- Stack: `[..., block_value]` → `[..., block_value]` (yield 復帰後)
- Stage: 3c.2
- `@yield_*` から `@pc` / `@cur_base` を restore。block_value は peek なので
  スタック top に残る

### `BLOCK_GIVEN_P` (0x4B)

- Operand: なし
- Stack: `[...]` → `[..., bool]`
- Stage: 3c.3
- `@cfp_block_pcs.last >= 0` なら TRUE_VAL、それ以外 FALSE_VAL

---

## クラス・インスタンス (Stage 3d.1)

### `INSTANCE_NEW` (0x4C)

- Operand: SLEB128 class_idx
- Stack: `[...]` → `[..., instance_ref]`
- Stage: 3d.1

実行詳細:

1. `n = total_ivar_count(class_idx)` (継承込み合計)
2. `@instance_ivar_pool` 末尾に NIL_VAL を n 個 push
3. `alloc_heap_slot(3, pool_offset, n, class_idx)` でヒープスロット確保
4. `(new_idx \<\< 3) | 0b110` を push

### `CALL_METHOD` (0x4D)

- Operand: SLEB128 name_packed, SLEB128 argc
- Stack: `[..., recv, arg_1, ..., arg_n]` → `[..., return_value]`
- Stage: 3d.1

実行詳細:

1. `recv` をスタック (top - argc) 位置から取得
2. `class_idx = class_of_value(recv)`
3. `m_idx = find_method_in_class(class_idx, name_packed)` (見つからなければ
   parent chain を walk、それでも無ければ NoMethodError)
4. 通常の CALL と同じ frame setup + `@cur_self = recv`
5. recv をスタックから除去 (call フレームに移った)

### `LOAD_SELF` (0x4E)

- Operand: なし
- Stack: `[...]` → `[..., @cur_self]`
- Stage: 3d.1

### `LOAD_IVAR` (0x4F)

- Operand: SLEB128 ivar_slot
- Stack: `[...]` → `[..., @instance_ivar_pool[base + ivar_slot]]`
- Stage: 3d.1
- base = `@heap_starts[unbox(@cur_self)]`

### `STORE_IVAR` (0x50)

- Operand: SLEB128 ivar_slot
- Stack: `[..., v]` → `[..., v]` (pop しない)
- Stage: 3d.1

### `CALL_METHOD_WITH_BLOCK` (0x51)

- Operand: SLEB128 name_packed, argc, block_pc, block_arity
- Stack: `CALL_METHOD` と同じ
- Stage: 3d.1
- `CALL_METHOD` + `CALL_WITH_BLOCK` のブロック紐付けを兼ねる

---

## DUP (Stage 3d.2)

### `DUP` (0x52)

- Operand: なし
- Stack: `[..., a]` → `[..., a, a]`
- Stage: 3d.2
- `Foo.new(args)` の compile-time 展開で、INSTANCE_NEW 後の instance を
  initialize の receiver と最終戻り値の両方に使うために導入

---

## 例外処理 (Stage 3e)

### `PUSH_HANDLER` (0x53)

- Operand: 3-byte 固定 SLEB128 catch_rel
- Stack: 変化なし
- Stage: 3e
- ハンドラスタック (5 並列 IntArray) に以下を push:
  - `catch_pc = @pc + catch_rel`
  - `ensure_pc` (rescue chain 末尾 → ensure へ fall-through)
  - 現在の `@stack.length` / `@cfp_pcs.length` / `@yield_pcs.length`

### `POP_HANDLER` (0x54)

- Operand: なし
- Stack: 変化なし
- Stage: 3e
- ハンドラスタック top を破棄 (begin 本体が正常終了したとき)

### `RAISE` (0x55)

- Operand: なし
- Stack: `[..., exc]` → unwind 後の状態
- Stage: 3e

実行詳細:

1. `@exception = pop`
2. ハンドラスタック top を pop しながら以下:
   - `@stack` を記録された深さまで縮小
   - `@cfp_*` を記録された深さまで巻き戻し (cfp_self / block / method_idx 等も)
   - `@yield_*` を記録された深さまで巻き戻し
   - `@pc = catch_pc`
3. 適合する handler が見つかるまで繰り返し
4. すべて巻き戻り切ったら未捕捉エラーで exit code 1

### `LOAD_EXCEPTION` (0x56)

- Operand: なし
- Stack: `[...]` → `[..., @exception]`
- Stage: 3e
- rescue で `=> e` 束縛時に使う

### `CLEAR_EXCEPTION` (0x57)

- Operand: なし
- Stack: 変化なし
- Stage: 3e
- `@exception = NIL_VAL`。マッチした rescue の最後で消化

### `CHECK_EXCEPTION_CLASS` (0x58)

- Operand: SLEB128 class_idx (-1 = catch-all)
- Stack: `[...]` → `[..., bool]`
- Stage: 3e
- `class_of_value(@exception)` が target class_idx の継承チェーン内にあれば TRUE
- class_idx == -1 は常に TRUE (catch-all)

### `RERAISE_OR_END` (0x59)

- Operand: なし
- Stack: 変化なし
- Stage: 3e
- ensure 末尾。`@exception != NIL_VAL` なら外側 handler へさらに unwind、
  NIL_VAL なら何もせず次へ流す

---

## super (Stage 3d.5)

### `CALL_SUPER` (0x5A)

- Operand: SLEB128 name_packed, SLEB128 argc
- Stack: `[..., recv, arg_1, ..., arg_n]` → `[..., return_value]`
- Stage: 3d.5

実行詳細:

1. `cur_m = @cfp_method_idx[-1]` (現フレームの method idx)
2. `defining_class = @method_class_idx[cur_m]`
3. `parent = @class_parent_idx[defining_class]` (= 検索開始は親から、自分は skip)
4. parent から chain を walk して `name_packed` を持つ method を探索
5. 見つかったら通常の CALL と同じ frame setup
6. 見つからなければ NoMethodError

receiver はスタック top - argc 位置の self (compile_super が `LOAD_SELF` を先に
emit している)。

---

## HALT (0xFF)

- Operand: なし
- Stack: 変化なし
- 実行終了 (トップレベル末尾に compiler が emit)
