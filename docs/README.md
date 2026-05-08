# setsunaruby 仕様ドキュメント

setsunaruby (Ruby サブセットを実装するスタックマシン型処理系 + JIT 設計) の
内部仕様を Progressive Disclosure で整理したドキュメント群。

実装の概要を素早く知りたい場合はトップから順に、特定レイヤを掘り下げたい場合は
該当サブディレクトリを直接開く。

## 全体像 (まずここから)

- [architecture-overview.md](architecture-overview.md) — Lexer → Parser → Compiler → VM の
  4 段パイプライン、ストリーミング処理、JIT 経路を 1 ページで概観

## レイヤ別仕様

- **Lexer (字句解析)**
  - [lexer/tokens.md](lexer/tokens.md) — トークン種別 (`TokenKind`)、`Token` の値の意味、
    識別子と文字列リテラルの packed 表現

- **Parser + Compiler (構文解析 + コード生成)**
  - [parser/ast-nodes.md](parser/ast-nodes.md) — `ASTNode` のフィールド構成と
    全 AST kind の意味
  - [parser/compile.md](parser/compile.md) — AST から bytecode を組み立てる規則
    (compile_stmt / compile_expr / 各構文の bytecode テンプレート)

- **Bytecode (中間表現 + VM)**
  - [bytecode/overview.md](bytecode/overview.md) — 値表現 (タグ付き即値)、ヒープ、
    コールフレーム、ハンドラスタック
  - [bytecode/opcodes.md](bytecode/opcodes.md) — 全 opcode の仕様 (hex、operand、
    stack effect、実行詳細)

- **JIT (ZJIT 風パイプライン、案 A まで完成)**
  - [jit/overview.md](jit/overview.md) — bytecode → HIR → 最適化 → LIR → arm64 機械語の流れ
  - [jit/hir.md](jit/hir.md) — `HirOp` 仕様、SoA レイアウト、SSA 化と型特化
  - [jit/lir.md](jit/lir.md) — `LirOp` 仕様、レジスタ割当、arm64 エンコード
  - [jit/status.md](jit/status.md) — 案 A (ダンプまで) と案 C (実機実行) の差分、
    spinel 拡張で必要な機能

## 設計上の前提

setsunaruby のすべてのレイヤに通底する制約は **「spinel の whole-program 型推論を
壊さないこと」**。具体的なルール (単一クラス + kind tag、ユーザクラス配列禁止、
bool フラグ禁止、`def self.xxx` 禁止 等) はリポジトリルートの [CLAUDE.md](../CLAUDE.md)
を参照。本仕様書では各レイヤで該当ルールがどう効いているかを脚注的に補足する。
