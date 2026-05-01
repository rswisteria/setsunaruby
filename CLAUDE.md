# setsunaruby

Ruby サブセットで実装するスタックマシン型処理系。**spinel で AOT コンパイル** して
ネイティブバイナリ化することが前提。学習目的のため、Stage を区切って機能を増やしていく。
最終ゴールは自己ホスト。詳細は `README.md` を参照。

## ビルド・テスト・ベンチ

```bash
make test-cruby        # CRuby 上で Stage 0/1 テスト全件
make test-aot          # spinel ビルド済みバイナリでテスト (build 必須)
make test-all          # 上記両方
make build             # ~/spinel/spinel で ./setsunaruby を生成
make bench             # AOT vs CRuby 性能比較 (build 必須)
make bench-regen       # benchmark/bench*.rb を seed 固定で再生成

ruby bin/setsunaruby.rb <file>    # CRuby で実行
./setsunaruby <file>              # AOT で実行 (build 必須)
```

spinel は `~/spinel/spinel` (シェル PATH の `~/bin/spinel` も同等)。`make build`
が呼び出す。spinel 自体のビルドはこのリポジトリの管轄外。

## リポジトリ運用

- **`main` への直接 push は禁止** (権限ポリシーで拒否される)。ブランチを切って PR 経由で merge。
- **ブランチ命名**: `feature/stage-N` (機能追加)、`bench/...` (ベンチ系)、`fix/...`、`chore/...`。
- **コミットメッセージ**: Semantic Commit Messages (`feat:`、`fix:`、`bench:`、`chore:` 等)、
  日本語サブジェクト OK。本文は何が変わったかではなく **なぜ変えたか** を書く。
- **PR 作成**: `gh pr create` を使う。Issue を Close する場合は body に `Closes #N`。
- **作業前にブランチを確認**: `main` 上で作業しないこと。

## Stage 進行と Issue 管理

各 Stage は GitHub Issue で管理。実装着手は新ブランチ + Issue を Closes 指定の PR で。

| Stage | 状態 |
|---|---|
| 0, 0.5, 1 | ✅ 完了 (#2 closed) |
| 2 (Method/再帰) | #3 |
| JIT | #4 |
| 3 (文字列・配列・ブロック・クラス・例外) | #5 (tracking) |
| ∞ 自己ホスト | #6 |

Stage 1 のパターン (ローカル変数表、`:seq` チェーン、ジャンプ patch up) は Stage 2 で
再利用可能。Stage を増やすときは README のロードマップ表も更新する。

## spinel 互換のための強制ルール

spinel の whole-program 型推論は厳しい。以下を破ると AOT ビルドエラーか実行時 SIGSEGV
になる。これらは「Ruby としては不自然だが setsunaruby では必須」のパターン群:

1. **多態は単一クラス + kind Symbol タグで表現する**。Struct のサブタイプ多態は禁止。
   `ASTNode` (kind: `:int_lit`/`:bin_op`/...) のように 1 クラスに統合する。

2. **`def self.xxx` (class/module method) を作らない**。spinel が param/return 型を
   `mrb_int` に固定して壊す。factory method はインライン化、ロジックは instance method
   または Interp の private method に置く。

3. **インスタンス変数にユーザクラスの配列を保持しない**。
   `@tokens = [Token...]` パターンは spinel が field を `sp_RbVal` (poly) に決め打ち
   して下流が型崩壊する。配列で持つのは IntArray (`@bytecode` `@stack` `@locals` 等) のみ。
   オブジェクト系はストリーミング処理 (lookahead 1 件) で消費する。

4. **クラス間でフィールド名を被らせない**。`Token.kind` と `ASTNode.kind` が同名だと
   spinel が両者を混同する。`ASTNode` は `node_kind` `node_op` 等 `node_` プレフィックス済み。

5. **頻繁に型として参照されるクラスはトップレベルに置く** (`module Setsunaruby` の外)。
   一部のコード生成パスで namespace prefix が落ち、`sp_Token` 等の未定義型エラーになる。
   `Token` `ASTNode` は現状トップレベル。

6. **`if X then :sym elsif Y then :sym2 ... end` の Symbol 戻り値形式を使わない**。
   spinel が `if (FALSE)` に折りたたんでロジックが消える。`result = :nop` で初期化、
   各分岐で `result = :sym` 代入、最後に `result` を返す形に統一。

7. **文字リテラル比較を避ける** (`c == "\n"` 等)。spinel が C 出力に改行を生展開して
   構文エラーになる。`@bytes = src.bytes` で Integer 配列化し ASCII コード定数 (`NL = 10`) で比較。

8. **`-1 << shift` を C で書かない** (signed shift UB)。`0 - (1 << shift)` に置換する。

9. **トップレベルのローカル変数を Lexer/Parser/VM 等のインスタンス受け渡しに使わない**。
   `bin/setsunaruby.rb` のトップレベルで `Setsunaruby::Interp.new...` を直書きすると
   `volatile` 修飾されて型不整合になる。`def run(path); ...; end; run(ARGV[0])` で
   関数内に閉じ込める。

10. **ASTNode/Token は多引数フルコンストラクタにする**。`new(kind, line) + setter`
    の 2段階構築は field 型推論を壊す。全フィールドを initialize 引数で受け取る。

11. **ローカル変数名等の名前識別は Symbol/sp_sym ではなく Integer (packed) にする**。
    `name.to_sym` を Token に乗せると Token のフィールド型が Token* と推論される
    壊滅的なバグが起きる。`@bytes` 上の `(start << 16) | len` の packed 値で扱う。

12. **ローカル bool 変数を「if 分岐切り替えのフラグ」として使わない**。
    `first = true; while ... ; if first ; A ; first = false ; else ; B ; end ; end`
    のような可変 bool ローカル変数を分岐に使うと、whole-program 推論が破壊され
    無関係なクラス (例: ASTNode) のフィールドが `sp_RbVal` (poly) と推論されて
    `iv_node_left = sp_RbVal` の型不整合でビルドエラーになる (JIT-3b の CFG 構築
    パスで顕在化)。代わりに `count = 0` の Integer カウンタで `if count == 0`
    判定するか、戻り値の式で bool を直接構築する。`fixnum?` `truthy?` 等の述語
    メソッドは bool 戻り値を直接返す形 (中間 bool ローカル変数なし) なら問題ない。

新しい AST kind や opcode を追加するときも上記すべてを守ること。Stage 1 までで
これらを破るとビルドが通らないことを実証済み。

## 検証フロー

機能追加・修正後は **必ず** 以下の順で検証する:

1. `ruby test/test_stage0.rb` および `ruby test/test_stage1.rb` (CRuby 全 pass)
2. `make build` (警告0、エラー0)
3. `ruby test/test_aot.rb` (AOT 全 pass)
4. `examples/*.rb` で `diff <(./setsunaruby X) <(ruby bin/setsunaruby.rb X)` が空

CRuby だけ pass で AOT が崩れるパターンは spinel 制約違反 (上記の強制ルール) が
ほぼ確実な原因。CRuby 動作だけで完了報告しないこと。

## ファイル構成 (要点)

- `bin/setsunaruby.rb`: エントリ。spinel ビルド対象。
- `lib/setsunaruby/interp.rb`: Lexer/Parser/Compiler/VM を統合した中核 (~700行)。
  Stage 0.5 で「クラス分割するとオブジェクト受け渡しで spinel が崩壊」という結論
  に至り、単一クラスにまとめている。
- `lib/setsunaruby/{token,ast,opcodes,object}.rb`: データ定義のみ。Token/ASTNode は
  トップレベル (上記 spinel ルール 5)。
- `examples/`: 動作確認用 .rb (hello / arith / fizzbuzz)。AOT テストでも参照。
- `test/test_stage{0,1}.rb`: 自前 assert + StringIO で stdout キャプチャ。minitest 等
  への依存はなし (spinel は標準 gem を持たない)。
- `test/test_aot.rb`: 子プロセス出力比較。`make build` 後に実行。
- `benchmark/`: ベンチマーク資産 + run/regen スクリプト。

## 作業時の流儀

- **大きな機能追加は `/feature-dev:feature-dev` を起点にする** (Phase 探索→計画→実装→レビュー)。
  ただし spinel 制約への配慮はこの CLAUDE.md と README で担保済みなので、Phase 2 の
  agent 探索は省略可能。
- **進捗管理は TaskCreate で**。Stage 内のサブタスクをチケット化して進める。
- **行き詰まったら最小再現を `/tmp/spinel_test_*.rb` に切り出して `~/spinel/spinel ... -c`
  で C 出力を読む**。原因の 90% は上記強制ルールのいずれか。

## やらないこと

- メイン会話で agent を多重に起動して context を膨らませる (この project は知識が
  CLAUDE.md と README に集約されているため、agent 探索の利得が小さい)。
- spinel 互換と引き換えに Ruby らしさを優先するリファクタ。学習目的の主軸は
  「spinel と協調できる Ruby サブセット」を発見・維持すること。
- 「CRuby で動くから OK」で完了報告。AOT で動かなければ仕事は終わっていない。
