# setsunaruby

Ruby 文法を持つ、スタックマシン型プログラミング言語の処理系。
処理系自身を Ruby で実装し、最終的には [spinel](https://github.com/) を
使って AOT で C にコンパイル・ネイティブバイナリ化することを目指す。

「刹那」(10⁻¹⁸) から命名。mruby / nanoruby / picoruby に続く、
さらに小さな Ruby 系列という位置付け。

## 現状: Stage 0 完了 / Stage 0.5 partial

最小のスタックマシンが動作する。実装機能:

- 整数リテラル (任意精度に拡張可能な SLEB128 埋め込み)
- 真偽値 / nil リテラル (`true` / `false` / `nil`)
- 算術演算 `+ - * / %`
- 比較演算 `== < > <= >=` (連鎖は禁止、Ruby と同じ)
- 単項マイナス `-x`
- 括弧によるグルーピング
- `puts <expr>` (Ruby と完全一致の出力セマンティクス)
- 行コメント `#`

```bash
ruby bin/setsunaruby.rb examples/hello.rb
# 7
# 3
# true
# -5
# ...

ruby test/test_stage0.rb
# 36 passed, 0 failed
```

spinel での AOT ビルドは Stage 0.5 で部分対応済み (CRuby 動作の前提に
影響しない範囲のリファクタを適用)。完全な spinel ビルドは Stage 1 で
AST 再設計時に再挑戦する。

## アーキテクチャ

```
ソース (.rb)
   │
   ▼  Lexer (lib/setsunaruby/lexer.rb)
トークン列
   │
   ▼  Parser (lib/setsunaruby/parser.rb, 手書き再帰下降)
AST (Array[ASTNode])
   │
   ▼  Compiler (lib/setsunaruby/compiler.rb)
バイトコード (Array of Integer)
   │
   ▼  VM (lib/setsunaruby/vm.rb)
実行 (メモリ上で直接、ファイル化なし)
```

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

1 バイトのオペコード + 可変長オペランド。整数リテラルは SLEB128 で埋め込む。

| Opcode | Hex | 動作 |
|---|---|---|
| PUSH_INT | 0x01 | SLEB128 整数を push |
| PUSH_TRUE / PUSH_FALSE / PUSH_NIL | 0x02 / 0x03 / 0x04 | 即値 push |
| ADD / SUB / MUL / DIV / MOD | 0x10–0x14 | 二項演算 |
| EQ / LT / GT / LE / GE | 0x20–0x24 | 比較 |
| PUTS | 0x30 | top を pop して出力 |
| HALT | 0xFF | 終了 |

### AST 表現

単一の `ASTNode` クラスに `kind` シンボルタグを持たせ、各ノード種別を
区別する (タグ付きユニオン的な設計)。kind の取りうる値:

- `:int_lit` → `int_value`
- `:bool_lit` → `bool_value`
- `:nil_lit`
- `:bin_op` → `op` (Symbol), `left` (ASTNode), `right` (ASTNode)
- `:unary_minus` → `operand`
- `:puts_stmt` → `operand`

これは spinel の whole-program 型推論との親和性を考慮した設計。
Ruby idiom 的には Struct のサブタイプ別ノードクラスを作りたいところ
だが、spinel はそうした多態 Struct フィールドを単一型に推論してしまう
ため、tagged-union パターンを採用している。

## ロードマップ

| Stage | 内容 | 状態 |
|---|---|---|
| 0 | 算術スタックマシン (式と puts のみ) | ✅ 完了 (CRuby、36 tests pass) |
| 0.5 | spinel 互換リファクタ + AOT ビルド | ⚠ partial (詳細は下記) |
| 1 | ローカル変数 + 制御構造 (if/while) | 未着手 |
| 2 | メソッド定義 + 呼び出し + 再帰 | 未着手 |
| JIT | ホットメソッド検出 + コード生成 | 未着手 |
| 3+ | 文字列・配列・ブロック・クラス・例外 | 未着手 |
| ∞ | 自己ホスト (setsunaruby を setsunaruby で動かす) | 究極目標 |

## Stage 0.5 (spinel 互換) の進捗

Stage 0.5 では、spinel ビルドに向けて以下のリファクタを実施した。
これらは **CRuby 動作を維持したまま** spinel 互換性を高める変更:

### 適用済み (CRuby 36 テスト全 pass を維持)

1. **AST のタグ付きユニオン化**
   - 元: `Struct.new` で `IntLit` / `BinOp` / `BoolLit` … 個別ノード型
   - 変更後: 単一 `ASTNode` クラス + `kind` Symbol で種別区別、未使用フィールドはデフォルト値
   - 理由: spinel が `BinOp.left` のような多態フィールドを単一型 (最後に見たクラス) に決め打ちしてしまう

2. **`Token` のフィールド型分離**
   - 元: `Token.value` が Integer / String / nil の poly
   - 変更後: `int_value` (Integer) と `str_value` (String) に分離、kind で参照先を決める
   - デフォルト値で常にすべてのフィールドが意味のある値を持つ

3. **`def self.xxx` (class/module method) の廃止**
   - spinel は `def self.foo(name, line)` の `name` 引数の型推論に失敗する
     (パラメータ型と戻り値型が `mrb_int` に固定される既知のバグ)
   - 影響範囲: `Token.kw` 等の factory method、`Leb128.encode_signed` 等
   - 対応: factory method を完全廃止し、構築は呼び出し元でインライン化。
     `Leb128` / `ObjectModel` はインスタンスメソッドを持つクラスに変更

4. **文字リテラル比較の整数化**
   - 元: `c == "\n"` のような単一文字 String 比較
   - 問題: spinel が C ソースに改行文字を生のまま埋め込んでしまう
   - 変更後: ソースを `@bytes = src.bytes` で Integer 配列化し、ASCII コード定数
     (`NL = 10`, `SP = 32` …) と比較

### 未解決 (Stage 1 で再挑戦)

以下の問題はまだ spinel ビルドを通せていない。Stage 1 で AST/コンパイラ
を変数・制御構造のために再設計するタイミングで、改めて取り組む:

1. **`unknown type name 'sp_ASTNode'`**
   - 名前空間 `Setsunaruby::ASTNode` への参照が、生成 C 内で名前空間プレフィックス
     なしの `sp_ASTNode` として展開される箇所がある
   - 仮説: `volatile` 修飾が掛かる polymorphic 配列要素から型解決する経路で、
     namespace 修飾が落ちている

2. **`@om` / `@leb` インスタンス変数の polymorphic 化**
   - `VM#initialize` 内の `@om = ObjectModel.new` の代入が `sp_RbVal` (多態値型) として
     推論される
   - 結果として `@leb.decode_signed(...)` が runtime poly dispatch (`cls_id == 4`) に
     変換され、引数型不整合を起こす
   - 仮説: 他のインスタンス変数 (`@code` / `@stack` / `@pc`) との「同居」で
     spinel が VM 全体を poly な値の集合と判断している可能性

3. **配列の volatile 修飾**
   - `Lexer.tokenize` の戻り値 Array[Token] が `volatile sp_PtrArray *` として推論
   - 「Array に複数の型が混入する可能性」を spinel が疑っている

これらは spinel の whole-program 型推論の振る舞いに関する深い問題で、
最小再現コードを切り出して spinel リポジトリ側に issue として
持ち込むのが筋。Stage 1 で AST が拡張される機会に、parallel-arrays
パターン (spinel 自身の `spinel_codegen.rb` がやっているような
SoA レイアウト) への全面移行も併せて検討する。

## ディレクトリ構成

```
.
├── bin/
│   └── setsunaruby.rb        # エントリポイント (spinel で AOT ビルドされる対象)
├── lib/
│   └── setsunaruby/
│       ├── token.rb          # Token クラス (kind + int_value/str_value/line)
│       ├── lexer.rb          # 字句解析 (バイト列ベース)
│       ├── ast.rb            # ASTNode クラス (kind タグ付き)
│       ├── parser.rb         # 構文解析 (手書き再帰下降)
│       ├── opcodes.rb        # Op:: オペコード定数
│       ├── object.rb         # ObjectModel + ObjectVal::NIL_VAL/TRUE_VAL/FALSE_VAL
│       ├── leb128.rb         # SLEB128 エンコード/デコード
│       ├── compiler.rb       # AST → バイトコード
│       └── vm.rb             # 実行ループ
├── examples/
│   ├── hello.rb              # puts 1 + 2 など
│   └── arith.rb              # 演算子優先順位確認
├── test/
│   └── test_stage0.rb        # 36 件のテスト (assert + 子プロセス出力比較)
└── Makefile
```

## 開発時のコマンド

```bash
# CRuby でサンプル実行
ruby bin/setsunaruby.rb examples/hello.rb

# テスト実行
ruby test/test_stage0.rb
# または
make test

# spinel で AOT ビルド (Stage 1 で完全対応予定)
make build
./setsunaruby examples/hello.rb
```

## 学習メモ: spinel との協調設計の知見

このプロジェクトを通じて、spinel の whole-program 型推論と協調する
ためのパターンが見えてきた:

- **多態は kind タグ + 単一クラスで表現**: Struct サブタイプは避ける
- **`def self.xxx` を使わない**: factory method はインライン化、インスタンスメソッドに移行
- **文字 (Char) は Integer (バイト値) として扱う**: 単一文字の String 比較は避ける
- **配列の初期型を確定させる**: `[]` だけでは型が決まらないことがある
- **名前空間内クラスの相互参照に注意**: 生成 C で名前空間プレフィックスが
  欠落するケースがある

これらは Ruby としてはやや窮屈だが、AOT コンパイルされる「言語実装の言語」
としては合理的な制約である。setsunaruby のようなプロジェクトでは、
**「Ruby のサブセットでホスト言語を書き、それで Ruby のサブセットを実装する」**
という構造になる。
