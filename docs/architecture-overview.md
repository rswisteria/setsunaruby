# アーキテクチャ概観

setsunaruby は Ruby ソースを 1 パスで bytecode に変換し、スタックマシン VM で
実行する。Lexer / Parser / Compiler / VM はすべて 1 つのクラス
(`Setsunaruby::Interp`) に統合され、**中間配列 (Token 列・AST 配列) を持たない
ストリーミング処理** で動く。

## パイプライン

```
ソース (.rb)
   │
   ▼  next_token         (1 トークンずつ生成)
Token  ───→ @cur_token
   │
   ▼  parse_statement    (LL(1) 再帰下降、トークンを 1 つ消費するごとに先読み更新)
ASTNode ───→ 即 compile_stmt に渡す
   │
   ▼  compile_stmt       (AST を bytecode に変換、@bytecode に push)
Bytecode (Integer 配列 @bytecode)
   │
   ▼  run_vm             (1 命令ずつフェッチ・実行)
実行結果 (stdout / 戻り値 / 例外)
```

各ステップの詳細:

- [lexer/tokens.md](lexer/tokens.md): Lexer が生成するトークン
- [parser/ast-nodes.md](parser/ast-nodes.md): Parser が組み立てる AST
- [parser/compile.md](parser/compile.md): Compiler が emit する bytecode のルール
- [bytecode/opcodes.md](bytecode/opcodes.md): VM が解釈する opcode

## なぜストリーミングなのか

複数クラス間でオブジェクト配列を受け渡すと、spinel の whole-program 型推論が
ユーザクラスのフィールドを `sp_RbVal` (poly value) と判定してしまい、型崩壊が
連鎖する。これを避けるため:

- `Token` は 1 個ずつ生成し、`@cur_token` に 1 件だけ保持
- `ASTNode` も同様。parse 中に複雑な木を保持するが、配列として ivar には載せない
- データ表は **並列 IntArray (SoA)**。`@method_name_starts` `@method_pcs` 等の
  並列配列で「メソッド表」を表現し、Method クラスの配列は持たない

詳細は [bytecode/overview.md](bytecode/overview.md) と [CLAUDE.md](../CLAUDE.md) を参照。

## JIT 経路

ホット検出されたメソッドは bytecode から HIR に持ち上げられて最適化され、
最終的に arm64 機械語までエンコードされる。実機実行は spinel 拡張待ちで
未対応 (= ダンプまで)。

```
@bytecode  ──┬─→ run_vm (通常実行)
             │
             └─→ build_hir → 最適化 4 パス → lower to LIR → encode arm64
                                                                │
                                                                ▼
                                                          ダンプのみ
                                                          (実機実行は案 C で)
```

詳細は [jit/overview.md](jit/overview.md)。

## 構成ファイル

| ファイル | 役割 |
|---|---|
| `bin/setsunaruby.rb` | エントリ。spinel ビルド対象 |
| `lib/setsunaruby/interp.rb` | Lexer / Parser / Compiler / VM の本体 (~5800 行) |
| `lib/setsunaruby/token.rb` | `TokenKind` 定数と `Token` クラス |
| `lib/setsunaruby/ast.rb` | `ASTNode` クラス |
| `lib/setsunaruby/opcodes.rb` | `Op` 定数 (bytecode opcode) |
| `lib/setsunaruby/object.rb` | `NIL_VAL` / `FALSE_VAL` / `TRUE_VAL` |
| `lib/setsunaruby/hir_opcodes.rb` | `HirOp` 定数 + `HirConstTag` |
| `lib/setsunaruby/lir_opcodes.rb` | `LirOp` 定数 + `Arm64Cond` |
