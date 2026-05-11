# JIT の動作状況と残タスク

JIT は **案 A (機械語ダンプまで) で完成**、**案 C (実機実行) は経路実装済み**
(spinel フォーク `setsunaruby-jit` に依存)。ただし JIT-side の機械語エンコーダに
未解決の課題が残るため、実機で動くのは現状「単一 BB / call なし」のメソッドのみ。

## 動作している範囲 (案 A)

`SETSUNARUBY_DUMP_HIR=1 ruby bin/setsunaruby.rb examples/fib.rb 2>&1` で以下が
確認できる:

- ホット検出ログ (`ZJIT: hot method detected (idx=N)`)
- HIR (raw / optimized) のダンプ
- CFG analysis (idom / DF) のダンプ
- LIR + arm64 機械語 hex のダンプ

これらはすべて STDERR への出力で、実際の bytecode 実行には影響しない。
通常実行は VM が `@bytecode` を解釈する経路で行われる。

## 動作している範囲 (案 C、新規)

`SETSUNARUBY_JIT=1 ./setsunaruby file.rb` (= AOT バイナリ + arm64 ホスト) で:

1. ホット閾値到達時に `build_and_dump_hir` を実行 → arm64 機械語生成
2. `install_jit_for_method` が `JIT.alloc` → `JIT.write_words` → `JIT.protect`
   (or `JIT.jit_write_protect`) → `JIT.clear_icache` を順に呼んで実行可能ページに転送
3. 以降のメソッド呼び出しは `exec_call_common` が `JIT.callN` で関数ポインタへ jmp
4. `@jit_fn_addrs[m_idx]` に転送先アドレスを cache

非 arm64 ホスト / arity > 8 / 空 LIR / install エラーのときは
`@jit_fn_addrs[m_idx] = -1` でマークし、通常のインタプリタ経路に流れる。

### 既知の制約

- **複数 BB を含むメソッドは crash する可能性が高い**: `encode_b` /
  `encode_b_cond` / `encode_bl` が BB id / method idx を imm26 / imm19 に
  リテラル埋めしているだけで、PC 相対 offset への解決が未実装。単一 BB
  (= 制御フロー無し) でかつ method 呼出無しのメソッドのみ安全。
- **arm64 ホスト以外では install しない**: x86_64 ホストでは setsunaruby JIT
  が x86_64 emitter を持たないため、SETSUNARUBY_JIT=1 を設定しても install は
  skip され、インタプリタで完走する。
- **CRuby + SETSUNARUBY_JIT=1 は自動 OFF**: `defined?(JIT)` が CRuby では nil
  を返すので、shim 無しでも自動的にインタプリタ実行になる。

## spinel への追加要件 (= 個人フォーク `setsunaruby-jit` ブランチ)

実機実行に必要な C プリミティブを spinel に追加してある。upstream には送らない。

`vendor/spinel-jit-primitives.patch` を `~/spinel` に当てて `make` で
`spinel_codegen` を再ビルドすること。`setsunaruby/Makefile` の `verify-spinel-jit`
target がパッチ適用済みかを確認する。

| 機能 | C シンボル | Ruby 公開名 |
|---|---|---|
| 実行可能メモリ確保 | `sp_jit_alloc(size, prot)` | `JIT.alloc(size, prot)` |
| 保護切替 | `sp_jit_protect(addr, size, prot)` | `JIT.protect(addr, size, prot)` |
| 解放 | `sp_jit_free(addr, size)` | `JIT.free(addr, size)` |
| W^X 切替 (Darwin arm64) | `sp_jit_write_protect(bool)` | `JIT.jit_write_protect(bool)` |
| 1 word 書き込み | `sp_jit_write_u32(addr, off, v)` | `JIT.write_u32(addr, off, v)` |
| 一括書き込み | `sp_jit_write_words(addr, ia)` | `JIT.write_words(addr, int_array)` |
| icache flush | `sp_jit_clear_icache(addr, size)` | `JIT.clear_icache(addr, size)` |
| 関数ポインタ呼び | `sp_jit_call0..call8(addr, ...)` | `JIT.call0..call8(addr, ...)` |
| ページサイズ | `sp_jit_page_size()` | `JIT.page_size` |
| 定数 | `SP_JIT_PROT_*` / `SP_JIT_DARWIN_ARM64` / `SP_JIT_ARCH_ARM64` | `JIT::PROT_READ` / `JIT::PROT_WRITE` / `JIT::PROT_EXEC` / `JIT::DARWIN_ARM64` / `JIT::ARCH_ARM64` |

## ロードマップ

| 案 | 完了度 | 内容 |
|---|---|---|
| A: ダンプまで | ✅ 完成 | HIR/LIR/機械語 hex を STDERR にダンプ |
| B: dlopen 経由 | — | 採用せず (`spinel-jit-primitives.patch` で直接 mmap する案 C に進んだため) |
| C: 実機実行 (1 BB) | ✅ 経路完成 | mmap + W^X + 関数ポインタ呼び + icache flush 全て実装 |
| C': 実機実行 (多 BB / call) | ❌ 未着手 | encode_b / b_cond / bl の PC-relative 解決が必要 |
| C'': x86_64 emitter | ❌ 未着手 | x86_64 ホスト上でも実機実行できるようにする |

## CRuby と AOT での挙動差

`SETSUNARUBY_DUMP_HIR=1` のダンプは **CRuby 実行時のみ** 視認できる。spinel AOT は
`STDERR.puts` を silent な no-op にコンパイルするため、AOT バイナリではログが出ない。
カウンタ更新・HIR 構築・最適化パス・LIR lower・arm64 エンコードの**ロジックそのものは
AOT でも動作している** (test_aot.rb で副作用がないことは確認済み)。

`SETSUNARUBY_JIT=1` は AOT バイナリ + arm64 ホストでのみ有効になる:

| 環境 | `SETSUNARUBY_JIT=1` の挙動 |
|---|---|
| CRuby (どんなホストでも) | `defined?(JIT)` が nil → 自動 OFF、インタプリタ実行 |
| AOT バイナリ + x86_64 ホスト | `JIT::ARCH_ARM64 == false` で install skip、インタプリタ実行 |
| AOT バイナリ + arm64 ホスト (Linux/Darwin) | install 試行、成功すれば JIT 経由実行 |

## なぜ「個人フォーク」方針を採るか

汎用的な Ruby AOT としての spinel に JIT primitives は本筋ではない (JIT は処理系設計
の趣味的テーマで、spinel ユーザーの大半は不要)。setsunaruby 専用の拡張として
`~/spinel` のローカルブランチに隔離し、upstream PR は送らない方針。
