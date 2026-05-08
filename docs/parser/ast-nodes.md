# Parser 仕様 — AST ノード

Parser (`parse_statement` 以下の `parse_*` 群) は LL(1) 再帰下降で `Token` を消費し、
`ASTNode` の木を組み立てる。木は ivar に保持されず、生成と同時に `compile_*` に
渡されて消費される (ストリーミング)。

## ASTNode クラス

`lib/setsunaruby/ast.rb` で定義。フィールド名に `node_` プレフィックスがついて
いるのは、spinel が `Token` と `ASTNode` のフィールドを混同しないようにするため
(spinel ルール 4)。

```ruby
class ASTNode
  attr_accessor :node_kind, :node_int_value, :node_bool_value,
                :node_op, :node_left, :node_right, :node_operand
end
```

7 フィールドの全引数 initialize で構築する (spinel ルール 10、後付け setter は禁止)。

| フィールド | 型 | 主な用途 |
|---|---|---|
| `node_kind` | Symbol (`:int_lit`, `:bin_op`, ...) | ノード種別 (多態タグ) |
| `node_int_value` | Integer | 整数値・packed 名前・class_idx・strlit_idx 等 |
| `node_bool_value` | Boolean | 真偽値リテラル / `super()` 明示フラグ等 |
| `node_op` | Symbol (`:add`, `:sub`, `:mul`, ...) | bin_op の演算子種別 (`:nop` = 未使用) |
| `node_left` | ASTNode \| nil | 左部分木 |
| `node_right` | ASTNode \| nil | 右部分木 |
| `node_operand` | ASTNode \| nil | 補助的な部分木 (1 つ追加で要るとき) |

`node_kind` で多態を表現する **単一クラス + kind tag** パターン (spinel ルール 1)。
サブタイプ多態を使うと spinel が壊れる。

## AST kind 一覧

`compile_stmt` / `compile_expr` の分岐から逆引きできる全 kind を以下にまとめる。

### 文 (compile_stmt が処理)

| `node_kind` | 構文 | 主要フィールド | 導入 Stage |
|---|---|---|---|
| `:puts_stmt` | `puts <expr>` | `node_operand` = expr | 0 |
| `:if_expr` | `if/elsif/else/end` | `node_left` = cond, `node_right` = then, `node_operand` = else | 1 |
| `:while_stmt` | `while ... end` | `node_left` = cond, `node_right` = body | 1 |
| `:method_def` | `def name(...) ... end` | `node_int_value` = name packed, `node_left` = params chain, `node_operand` = body | 2 |
| `:class_def` | `class Name [< Parent] ... end` | `node_int_value` = name packed, `node_left` = body, `node_right` = `:class_parent_ref` or nil | 3d.1 / 3d.4 |
| `:return_stmt` | `return <expr>` | `node_operand` = expr (省略時は `:nil_lit`) | 2 |
| `:seq` | 連続文 | `node_left` = head stmt, `node_right` = tail seq | 1 |

`:seq` は複数文を**右結合チェーン**で表現 (`a; b; c` → `seq(a, seq(b, c))`)。
spinel が配列を扱いやすくするための工夫。

### リテラル

| `node_kind` | 構文 | フィールド |
|---|---|---|
| `:int_lit` | `42` | `node_int_value` = 整数値 |
| `:str_lit` | `"hello"` | `node_int_value` = strlit_idx |
| `:bool_lit` | `true` / `false` | `node_bool_value` = true/false |
| `:nil_lit` | `nil` | (なし) |
| `:self_lit` | `self` | (なし) |
| `:array_lit` | `[a, b, c]` | `node_left` = `:arg_cons` チェーン |

### 変数・代入

| `node_kind` | 構文 | フィールド |
|---|---|---|
| `:var_ref` | `x` (識別子参照) | `node_int_value` = name packed |
| `:assign` | `x = expr` | `node_int_value` = name packed, `node_operand` = expr |
| `:ivar_ref` | `@x` | `node_int_value` = name packed (`@` を含まない) |
| `:ivar_assign` | `@x = expr` | `node_int_value` = name packed, `node_left` = expr |

### 演算

| `node_kind` | フィールド |
|---|---|
| `:bin_op` | `node_op` ∈ {`:add`,`:sub`,`:mul`,`:div`,`:mod`,`:lshift`,`:shr`,`:band`,`:bor`,`:bxor`,`:eq`,`:neq`,`:lt`,`:gt`,`:le`,`:ge`,`:land`,`:lor`}、`node_left` = lhs、`node_right` = rhs |
| `:unary_minus` | `node_operand` = expr。compiler は `0 - operand` で展開 |
| `:unary_bnot` | `~x` 整数ビット反転 (Stage 4a)、`node_operand` = expr |
| `:unary_not` | `!x` 真偽反転 (Stage 4a)、`node_operand` = expr |

単項マイナスは `bin_op(:sub, int_lit(0), x)` 等価ではなく、parser が `int_lit` の
時は値を直接負にして埋め込む (`int_lit(-x)`)。それ以外は `bin_op(:sub, 0, x)`
パターンで生成する。

`:land` (`&&`) と `:lor` (`||`) は **短絡評価**のため compiler が `JUMP_IF_FALSE` /
`JUMP_IF_TRUE` で展開する (Stage 4a、`compile_short_circuit_and` /
`compile_short_circuit_or`)。中間 bool ローカル変数を作らないため spinel ルール 12
に違反しない。

### 関数呼び出し・ブロック

| `node_kind` | 構文 | フィールド |
|---|---|---|
| `:method_call` | `foo(args)` (暗黙 self) | `node_int_value` = name packed, `node_left` = `:arg_cons` chain, `node_right` = `:block_arg` or nil |
| `:method_call_on` | `obj.foo(args)` | `node_int_value` = name packed, `node_left` = receiver, `node_right` = `:block_arg` or nil, `node_operand` = `:arg_cons` chain |
| `:yield_expr` | `yield <expr>` | `node_left` = arg expr (or nil) |
| `:super_call` | `super` / `super(args)` / `super()` | `node_left` = `:arg_cons` chain or nil, `node_bool_value` = true なら `super()` 明示 |
| `:block_arg` | `do |x| body end` / `{ |x| body }` | `node_int_value` = param packed (なければ 0), `node_left` = body |

### 引数・パラメータチェーン

| `node_kind` | 用途 | フィールド |
|---|---|---|
| `:arg_cons` | 引数リスト (`a, b, c`) を右結合 cons 化 | `node_left` = head expr, `node_right` = tail cons or nil |
| `:param_cons` | パラメータリストを右結合 cons 化 | `node_int_value` = param packed, `node_right` = tail cons or nil |

### 例外処理 (Stage 3e)

| `node_kind` | 構文 | フィールド |
|---|---|---|
| `:begin_rescue` | `begin/rescue/ensure/end` | `node_left` = body, `node_right` = rescue chain (`:rescue_chain`), `node_operand` = ensure body or nil |
| `:rescue_chain` | rescue 節 1 つ | `node_int_value` = class_idx (-1 = catch-all), `node_left` = body, `node_right` = next rescue or nil, `node_operand` = `:ivar_ref`/`assign` か Bind なし |
| `:raise` | `raise "msg"` / `raise SomeClass.new(...)` | `node_left` = exception expr |

詳細な束縛仕様は `parse_rescue_chain` (interp.rb:1427) を参照。

### クラス親子参照

| `node_kind` | 用途 |
|---|---|
| `:class_parent_ref` | `class B \< A` の `\< A` を保持 (`node_int_value` = parent name packed) |

## 構築ルールの基本原則

1. **戻り値**: `parse_*` メソッドは ASTNode を返す。終端 (リテラル) は `parse_primary`、
   それ以外は `parse_*` の連鎖
2. **左結合**: 二項演算は `parse_X_continue` パターンで while ループ的に左結合。
   precedence: comparison \> shift \> additive \> multiplicative \> unary \> primary
3. **`then` / `do` の省略許容**: `skip_then_or_newlines` `skip_do_or_newlines` で吸収
4. **`begin` のショートカット**: `begin` を含まない文脈で出現したら `parse_begin_rescue` に
   委譲 (interp.rb:1202)
5. **`super` は method 内のみ**: parser は通すが compile 時に `@in_method` チェックで弾く

## AST から bytecode への流れ

`compile_stmt` / `compile_expr` がノードの `node_kind` を見て分岐し、`@bytecode`
配列に opcode と SLEB128 オペランドを push する。詳細は
[parser/compile.md](compile.md) を参照。
