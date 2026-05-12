# JIT の動作状況と残タスク

JIT は **案 A (機械語ダンプまで) で完成**、**案 C 実機実行は arm64 で
multi-BB / 自己再帰 / spill 含めて動作** (spinel フォーク `setsunaruby-jit`
に依存)。fib(10) が `SETSUNARUBY_JIT=1` で CRuby と一致するレベル。
ただし cross-method 呼び出しと if-expression を最終式とするメソッドは
install 拒否され bytecode で動作する。

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

### 既知の制約 / install 拒否される method

- **cross-method の BL**: 自己再帰 (`BL` の callee が自分の `m_idx` と等しい)
  のみ install を許可。他メソッド呼び出しは callee の JIT アドレスが事前
  解決できないため install を中止し bytecode 経路に流す。
- **if-expression を最終式とする method**: 例 `def f(n); if n<2; n; else; ...; end; end`。
  HIR builder が implicit な stack-top の phi 化を行わないため Return が
  一方の分岐の値しか参照しない不完全な HIR が生成される。`install_jit_for_method`
  の dominance チェックがこれを検出して install 拒否、bytecode で動作する。
  明示的なローカル変数経由 (`result = ...`) なら正しく phi 化されて JIT 化可能。
- **x86_64 ホスト**: encoder は arm64 と同等 (linear-scan + spill + FRAME_ENTER 等
  に対応) だが label fixup が未実装のため、multi-BB / BL を含むメソッドは
  install 拒否される。leaf method (id / add 等) は実機実行可能の見込み
  (x86_64 Linux での確認は環境待ち)。
- **CRuby + SETSUNARUBY_JIT=1 は自動 OFF**: `defined?(JIT)` が CRuby では nil
  を返すので、shim 無しでも自動的にインタプリタ実行になる。

### Register allocator (案 C v2)

`pass_compute_live_ranges` + `pass_allocate_registers` の素朴 linear-scan が
hir_id ごとに `[lr_start, lr_end]` を計算して 5 個の callee-saved レジスタ
プール (arm64: X19..X23 / x86_64 SysV: rbx, r12..r15) を奪い合う。あふれは
spill slot (frame 内の SP/RBP 相対) に書き出す:

| LirOp | 用途 |
|---|---|
| `LOAD_STACK dst, slot` | 各 use の直前で SCRATCH に load |
| `STORE_STACK slot, src` | 各 def の直後で frame の slot に store |
| `FRAME_ENTER #frame_size` | prologue: FP/LR push + callee-saved save + spill area 確保 |
| `FRAME_LEAVE #frame_size` | epilogue: callee-saved restore + frame 解放 |
| `ADD_IMM dst, src, #imm12` | boxed Fixnum 補正用 (FIXNUM_ADD = ADD; SUB_IMM #1) |
| `SUB_IMM dst, src, #imm12` | 同上 (FIXNUM_SUB = SUB; ADD_IMM #1) |

予約 reg: arm64 X16/X17 (= IP0/IP1)、x86_64 r10/r11 が spill scratch。

PHI は hir_id 順序的に末尾に append されるが、論理的に BB 先頭で値が確定する
ため `lr_start = bb_first_insn[bb]` に補正して allocator が phi の def より
先に use を処理することを防ぐ。allocator は hir_id 順ではなく lr_start 昇順に
selection sort してから linear scan を行う。

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
| 一括 word 書き込み (arm64) | `sp_jit_write_words(addr, ia)` | `JIT.write_words(addr, int_array)` |
| 一括 byte 書き込み (x86_64) | `sp_jit_write_bytes(addr, ia)` | `JIT.write_bytes(addr, int_array)` |
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
| C': 実機実行 (多 BB / call) | ✅ 完成 (arm64) | linear-scan register allocation + spill + 2-pass label fixup + 自己再帰 BL + PROLOGUE パラメタ化。`make test-jit-recursion` で fib(10) が JIT 完走 |
| C'': x86_64 emitter | ✅ encoder のみ | `pass_encode_x86_64` で SysV AMD64 の byte 列生成。byte 列単体テストで検証 (`make test-jit-x86-64`)。x86_64 Linux での multi-BB label fixup は未実装 |

## CRuby と AOT での挙動差

`SETSUNARUBY_DUMP_HIR=1` のダンプは **CRuby 実行時のみ** 視認できる。spinel AOT は
`STDERR.puts` を silent な no-op にコンパイルするため、AOT バイナリではログが出ない。
カウンタ更新・HIR 構築・最適化パス・LIR lower・arm64 エンコードの**ロジックそのものは
AOT でも動作している** (test_aot.rb で副作用がないことは確認済み)。

`SETSUNARUBY_JIT=1` は AOT バイナリ + arm64 ホストでのみ有効になる:

| 環境 | `SETSUNARUBY_JIT=1` の挙動 |
|---|---|
| CRuby (どんなホストでも) | `defined?(JIT)` が nil → 自動 OFF、インタプリタ実行 |
| AOT バイナリ + x86_64 ホスト | x86_64 byte 列を生成、`JIT.write_bytes` で install 試行 (実機検証は未) |
| AOT バイナリ + arm64 ホスト (Linux/Darwin) | install 試行、成功すれば JIT 経由実行 |

## なぜ「個人フォーク」方針を採るか

汎用的な Ruby AOT としての spinel に JIT primitives は本筋ではない (JIT は処理系設計
の趣味的テーマで、spinel ユーザーの大半は不要)。setsunaruby 専用の拡張として
`~/spinel` のローカルブランチに隔離し、upstream PR は送らない方針。
