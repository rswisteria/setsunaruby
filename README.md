# setsunaruby

Ruby 文法を持つ、スタックマシン型プログラミング言語の処理系。
処理系自身を Ruby で実装し、[spinel](https://github.com/) を
使って AOT で C にコンパイル・ネイティブバイナリ化する。

「刹那」(10⁻¹⁸) から命名。mruby / nanoruby / picoruby に続く、
さらに小さな Ruby 系列という位置付け。

## 現状: Stage 0 / 0.5 / 1 / 2 / JIT-1 / JIT-2 / JIT-3a / JIT-3b1 / JIT-3b2 / JIT-3b3 / JIT-3c 完了

スタックマシン上で **再帰 `fib(20)` / アッカーマン / tarai が CRuby + spinel AOT 両方で動作**。

実装機能:

- 整数リテラル (任意精度に拡張可能な SLEB128 埋め込み)
- 真偽値 / nil リテラル (`true` / `false` / `nil`)
- 算術演算 `+ - * / %`
- 比較演算 `== < > <= >=` (連鎖は禁止、Ruby と同じ)
- 単項マイナス `-x`
- 括弧によるグルーピング
- `puts <expr>` (Ruby と完全一致の出力セマンティクス)
- 行コメント `#` (マルチバイトコメント対応)
- ローカル変数の代入と参照 `x = 1`, `y = x + 1` (右結合)
- `if / elsif / else / end` (Ruby 同様の式扱い、値を返す)
- `while / end` ループ
- truthy/falsy: `nil` と `false` のみ偽、それ以外は真 (0 も真)
- **トップレベル `def name(p1, p2) ... end`** メソッド定義
- **メソッド呼び出し** `name(arg1, arg2)` (引数 0 個は `()` 省略可)
- **再帰** (自己再帰のみ。1 パスコンパイラのため相互再帰は不可)
- **`return <expr>`** 早期離脱 (省略時の戻り値は最後の式)
- **値渡しと独立スコープ** (メソッド内ローカルはトップレベルと別領域)

## クイックスタート

```bash
# CRuby で実行
ruby bin/setsunaruby.rb examples/hello.rb

# spinel で AOT ビルドしてネイティブバイナリ化
make build       # ./setsunaruby を生成

# AOT 実行
./setsunaruby examples/hello.rb

# テスト (CRuby Stage 0:38 + Stage 1:28 + Stage 2:26 + JIT-1/2/3a/3b1/3b2/3b3/3c:94 / AOT:47)
make test-cruby
make test-aot
make test-all
```

## ベンチマーク

| ワークロード | CRuby | AOT | speedup |
|---|---:|---:|---:|
| hello.rb (最小) | ~55 ms | ~3 ms | 約 19x |
| Stage 0 平均 (5種類 × 2000行) | ~80 ms | ~4 ms | 約 18x |
| **FizzBuzz N=5000 (Stage 1 ループ)** | **73 ms** | **2.5 ms** | **約 29x** |

ループや分岐を含む実用的なワークロードで AOT 版は CRuby 比 約 30 倍高速。
spinel の C コード生成 + GC 最適化 + ネイティブ実行の効果。`make bench` で再現可能。

## アーキテクチャ

```
ソース (.rb)
   │
   ▼  Interp.next_token (字句解析、1トークンずつ)
Token (1個ずつ消費)
   │
   ▼  Interp.parse_statement (LL(1) 再帰下降)
ASTNode
   │
   ▼  Interp.compile_statement
バイトコード (Array of Integer)
   │
   ▼  Interp.run_vm
実行 (メモリ上で直接、ファイル化なし)
```

**Lexer / Parser / Compiler / VM を 1 つの `Interp` クラスに統合**。
中間配列 (tokens, stmts) を保持せず、トークンを 1 つずつ生成しながら parse、
parse 結果の AST も即座に compile してバイトコードに追記、最後に VM 実行。

これは spinel の whole-program 型推論との親和性のための設計。
複数のクラス間でオブジェクト配列を受け渡すと poly value 化されて
型推論が崩壊するため、配列を持たないストリーミング処理にしている。

### オブジェクト表現

CRuby の `VALUE` を踏襲したタグ付き即値方式。

| 値 | obj_id (Integer) |
|---|---|
| nil | 0 |
| false | 2 |
| true | 4 |
| Fixnum | `(n << 1) \| 1` (LSB=1) |
| ヒープオブジェクト (Stage 1+) | `(idx << 3) \| 0b110` |

### バイトコード

1 バイトのオペコード + 可変長 / 固定長オペランド。

| Opcode | Hex | オペランド | 動作 |
|---|---|---|---|
| PUSH_INT | 0x01 | SLEB128 整数 | 即値 push |
| PUSH_TRUE / PUSH_FALSE / PUSH_NIL | 0x02–0x04 | – | 即値 push |
| POP | 0x05 | – | 破棄 |
| STORE_LOCAL | 0x06 | SLEB128 idx | top を local[idx] に格納 (POPしない) |
| LOAD_LOCAL | 0x07 | SLEB128 idx | local[idx] を push |
| JUMP | 0x08 | 固定 3byte SLEB128 | 無条件相対ジャンプ |
| JUMP_IF_FALSE | 0x09 | 固定 3byte SLEB128 | top を pop し偽ならジャンプ |
| ADD / SUB / MUL / DIV / MOD | 0x10–0x14 | – | 二項演算 |
| EQ / LT / GT / LE / GE | 0x20–0x24 | – | 比較 |
| PUTS | 0x30 | – | top を pop して出力、nil を push |
| CALL | 0x40 | SLEB128 method_idx | メソッド呼び出し (引数 argc 個 pop、結果 push) |
| RETURN | 0x41 | – | コールフレーム破棄して呼び出し元へ |
| HALT | 0xFF | – | 終了 |

ジャンプオフセットは patch up の都合で **固定 3 バイト SLEB128** (±1M バイト範囲)。
他の整数オペランド (整数リテラル、ローカル変数 idx) は通常の可変長 SLEB128。

### AST 表現

単一の `ASTNode` クラスに `node_kind` シンボルタグを持たせ、各ノード種別を区別。
フィールド名に `node_` プレフィックスを付けることで `Token` (`kind`, `int_value`) と
spinel の型推論で混同されるのを防いでいる。

`node_kind` の値:
- `:int_lit` → `node_int_value` (Integer 値)
- `:bool_lit` → `node_bool_value`
- `:nil_lit`
- `:bin_op` → `node_op` (Symbol)、`node_left`、`node_right`
- `:unary_minus` → `node_operand`
- `:puts_stmt` → `node_operand`
- `:assign` → `node_int_value` (変数名の packed (start<<16)|len)、`node_left` (値式)
- `:var_ref` → `node_int_value` (同上)
- `:if_expr` → `node_left` (cond)、`node_right` (then_body)、`node_operand` (else_body / nil)
- `:while_stmt` → `node_left` (cond)、`node_right` (body)
- `:seq` → `node_left` (current stmt)、`node_operand` (rest of seq)
- `:method_def` → `node_int_value` (名前 packed)、`node_left` (`:param_cons` チェーン)、`node_operand` (body)
- `:method_call` → `node_int_value` (名前 packed)、`node_left` (`:arg_cons` チェーン)
- `:return_stmt` → `node_operand` (戻り値式)
- `:param_cons` → `node_int_value` (param 名 packed)、`node_operand` (次の `:param_cons` or nil)
- `:arg_cons` → `node_left` (引数式)、`node_operand` (次の `:arg_cons` or nil)

ローカル変数名は **`@bytes` 上のバイト範囲 (start, len) で識別**。
Symbol/sp_sym を経由すると spinel の Token フィールド型推論が崩壊するため、
すべて整数 packed 値で表現。

## ロードマップ

| Stage | 内容 | 状態 |
|---|---|---|
| 0 | 算術スタックマシン (式と puts のみ) | ✅ 完了 |
| 0.5 | spinel 互換 + AOT ビルド | ✅ 完了 |
| 1 | ローカル変数 + 制御構造 (if/while) | ✅ 完了 (FizzBuzz 動作) |
| 2 | メソッド定義 + 呼び出し + 再帰 | ✅ 完了 (fib(20) / アッカーマン / tarai 動作) |
| JIT-1 | プロファイル収集 + ホットメソッド検出 (ZJIT 風) | ✅ 完了 (CRuby でログ視認) |
| JIT-2 | bytecode → HIR (lite SSA) 変換 + ダンプ | ✅ 完了 (`SETSUNARUBY_DUMP_HIR=1` で出力) |
| JIT-3a | HIR 最適化: fold_constants + eliminate_dead_code | ✅ 完了 (raw / optimized を両方ダンプ) |
| JIT-3b1 | basic block + CFG + clean_cfg | ✅ 完了 (BB 単位ダンプ + preds 表示) |
| JIT-3b2 | dominator tree + dominance frontier + CFG 分析ダンプ | ✅ 完了 (Cooper iterative + Cytron DF) |
| JIT-3b3 | phi 挿入 + variable renaming (本格 SSA 化) | ✅ 完了 (Cytron + LoadParam) |
| JIT-3c | プロファイル収集 + type_specialize + GuardFixnum | ✅ 完了 (Fixnum 特化命令) |
| JIT-4 | LIR + arm64 codegen + ディスパッチ切替 + side exit | 未着手 |
| 3+ | 文字列・配列・ブロック・クラス・例外 | 未着手 |
| ∞ | 自己ホスト (setsunaruby を setsunaruby で動かす) | 究極目標 |

## ディレクトリ構成

```
.
├── bin/
│   └── setsunaruby.rb        # エントリポイント (spinel で AOT ビルドされる対象)
├── lib/
│   └── setsunaruby/
│       ├── token.rb          # Token クラス (トップレベル) + TokenKind 定数
│       ├── ast.rb            # ASTNode クラス (トップレベル)
│       ├── opcodes.rb        # Op:: オペコード定数
│       ├── hir_opcodes.rb    # HirOp:: HIR 命令種別 + HirConstTag (JIT-2)
│       ├── object.rb         # ObjectVal::NIL_VAL/TRUE_VAL/FALSE_VAL
│       └── interp.rb         # Lexer/Parser/Compiler/VM 統合クラス
├── examples/
│   ├── hello.rb
│   ├── arith.rb
│   ├── fizzbuzz.rb           # Stage 1: ローカル変数 + 制御構造のショーケース
│   └── fib.rb                # Stage 2: 再帰のショーケース
├── test/
│   ├── test_stage0.rb        # CRuby Stage 0 テスト (38件)
│   ├── test_stage1.rb        # CRuby Stage 1 テスト (28件)
│   ├── test_stage2.rb        # CRuby Stage 2 テスト (26件)
│   ├── test_stage_jit.rb     # CRuby JIT-1/2/3a/3b1/3b2/3b3/3c テスト (94件)
│   └── test_aot.rb           # AOT テスト (47件)
├── setsunaruby               # spinel ビルド成果物 (gitignore)
└── Makefile
```

## spinel と協調するための設計知見 (Stage 0.5 で得たもの)

spinel の whole-program 型推論で setsunaruby を AOT ビルド可能にする
ために、以下の制約を踏まえた書き方をしている。これは将来の Stage で
新機能を追加するときの指針になる:

1. **多態は `kind` Symbol タグで表現**
   - Struct のサブタイプによる多態は spinel の field 型推論で破綻する
   - 全ノードを単一クラス + kind タグの tagged-union 風で表現

2. **`def self.xxx` (class method) を使わない**
   - factory method はインライン化、または instance method に変換
   - spinel が parameter 型推論に失敗する既知のパターン

3. **オブジェクト配列を `instance variable` に保持しない**
   - `@tokens = [Token...]` のような保持は poly 推論を引き起こし下流崩壊
   - 中間データはストリーミング処理で消費する (lookahead 1 token のみ保持)

4. **多用する class のフィールド名はクラス間で重複させない**
   - `Token.kind` と `ASTNode.kind` のように同名フィールドがあると
     spinel が両クラスを混同する
   - ASTNode は `node_kind` `node_op` のようにプレフィックス付与で回避

5. **`if X then :a elsif Y then :b ... end` 形式を避ける**
   - 戻り値が Symbol の if-then-elsif 形式は spinel が誤コンパイルする
     ことがある (`if (FALSE)` 折りたたみ)
   - `result = :nop` で初期化し各分岐で代入、最後に `result` を返す形に

6. **トップレベルクラス vs `module Setsunaruby` 内クラス**
   - 一部のコード生成パス (volatile 宣言など) で名前空間プレフィックスが
     落ちることがある
   - `Token` `ASTNode` のように頻繁に型として参照されるクラスは
     トップレベル (module 外) に置く

7. **文字リテラル比較を避ける**
   - `c == "\n"` は spinel の C 出力で改行が生展開されてバグる
   - ソースを byte 配列に変換し、ASCII コード定数 (`NL = 10`) で整数比較

8. **トップレベルローカル変数の `volatile` 修飾を回避**
   - `bin/setsunaruby.rb` のトップレベル変数は `volatile` 修飾されて
     型不整合を引き起こす
   - `def run(path); ...; end; run(ARGV[0])` のように関数内に閉じ込める

これらは Ruby としてはやや窮屈だが、AOT コンパイルされる「言語実装の言語」
としては合理的な制約。将来 Stage 1+ で機能追加するときも、これらの
パターンに従う。
