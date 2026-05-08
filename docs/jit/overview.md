# JIT 概観

setsunaruby の JIT は **ZJIT (Ruby 4.0)** を参考にした教科書的なパイプライン。
bytecode → HIR → 最適化 → LIR → arm64 機械語までを実装している。
**ダンプまでは完成済みだが、生成した機械語を CPU に実行させる経路は未着手**
(spinel 拡張待ち)。詳細は [status.md](status.md)。

## パイプライン

```
                        ┌── JIT_HOT_THRESHOLD 到達でホット検出 ──┐
                        │                                          │
@bytecode  ─→ run_vm  ──┤                                          │
                        │                                          ▼
                        │                                  build_hir
                        │                                  (bytecode → HIR)
                        │                                          │
                        │                                          ▼
                        │                                  pass_fold_constants
                        │                                  pass_eliminate_dead_code
                        │                                  pass_build_cfg
                        │                                  pass_clean_cfg
                        │                                  pass_compute_dom
                        │                                  pass_compute_df
                        │                                  pass_insert_phis
                        │                                  pass_rename_vars
                        │                                  pass_type_specialize
                        │                                          │
                        │                                          ▼
                        │                                  pass_lower_to_lir
                        │                                          │
                        │                                          ▼
                        │                                  pass_encode_arm64
                        │                                          │
                        │                                          ▼
                        │                                  HIR/LIR ダンプ + 機械語 hex
                        │                                          │
                        └────  ホット未満なら通常実行で完結 ──────┘
```

## 各サブステージ

| サブステージ | 役割 | 詳細 |
|---|---|---|
| JIT-1 | 呼出回数プロファイル + ホット検出 | `@jit_call_counts` IntArray |
| JIT-2 | bytecode → HIR (lite SSA) | [hir.md](hir.md) |
| JIT-3a | 定数畳み込み + 不要コード削除 | [hir.md](hir.md#最適化パス) |
| JIT-3b1 | basic block + CFG + clean_cfg | [hir.md](hir.md#cfg) |
| JIT-3b2 | dominator tree + dominance frontier | [hir.md](hir.md#dominator) |
| JIT-3b3 | phi 挿入 + variable renaming (本格 SSA) | [hir.md](hir.md#ssa) |
| JIT-3c | 型プロファイル + GuardFixnum + Fixnum 特化 | [hir.md](hir.md#型特化) |
| JIT-4 (案 A) | HIR → LIR + arm64 エンコード + ダンプ | [lir.md](lir.md) |
| JIT-4 (案 C) | mmap + W^X 切替 + 関数ポインタ呼び出し + 実機実行 | **未実装** ([status.md](status.md)) |

## 起動条件

`exec_call` のたびに `@jit_call_counts[m_idx] += 1`。`JIT_HOT_THRESHOLD` ちょうどに
達した瞬間に **1 回だけ** ホット検出ログを STDERR に出し、以降のパス群を実行する。

```ruby
JIT_ENABLED = true
JIT_HOT_THRESHOLD = 100  # 値はコード参照 (例)
```

`SETSUNARUBY_DUMP_HIR=1` 環境変数が立っていれば HIR/LIR/機械語ダンプを STDERR に
出力する (CRuby 実行時のみ。AOT は `STDERR.puts` が no-op なので silent)。

## JIT で扱わない機能

以下を含む method は HIR/LIR が未対応のため、コンパイル時点で
`mark_current_method_jit_unsafe` が `@jit_call_counts[m_idx] = JIT_HOT_THRESHOLD`
にプリセットしてホット検出から除外する。

- `super` (Stage 3d.5)
- `begin/rescue/ensure/raise` (Stage 3e)
- `class` 関連 (`INSTANCE_NEW` / `CALL_METHOD` / `LOAD_IVAR` / 等) は LIR には
  lower しないが、HIR レベルではダンプ可能 (型不明のため特化されないだけ)

JIT が扱える代表例: `def fib(n); ...; end` のような Fixnum 算術 + 制御フロー +
自己再帰のメソッド。

## データレイアウト概観

すべて並列 IntArray (SoA、spinel ルール 3)。

### HIR

| ivar | 内容 |
|---|---|
| `@hir_kind/op0/op1/op2` | 1 命令 = (kind, op0, op1, op2) |
| `@hir_call_args` | CALL/ARRAY_NEW/YIELD 等の可変長引数を flat に保持 |
| `@hir_deleted` | 0/1 で論理削除 (DCE 用) |
| `@hir_bb` | 各 hir_id の所属 BB |
| `@hir_phi_args` | phi の (BB, value) ペアを flat に保持 |
| `@hir_rename_target` | rename で各 hir_id を redirect する先 |
| `@hir_bc_pc` | 各 hir_id の出処 bytecode PC (型プロファイル参照用) |

### CFG / Dominator

| ivar | 内容 |
|---|---|
| `@bb_first_insn` / `@bb_last_insn` | BB の hir_id 範囲 |
| `@bb_succ0` / `@bb_succ1` | 後続 BB (JUMP_IF_FALSE では succ0=偽分岐、succ1=真分岐) |
| `@bb_preds_starts` / `@bb_preds_counts` / `@bb_preds_flat` | 各 BB の前任 BB |
| `@bb_idom` | immediate dominator |
| `@bb_df_starts` / `@bb_df_counts` / `@bb_df_flat` | dominance frontier |
| `@bb_dom_children_starts` / `@bb_dom_children_counts` / `@bb_dom_children_flat` | dominator tree の子 |

### LIR

| ivar | 内容 |
|---|---|
| `@lir_kind/op0/op1/op2` | 1 命令 = (kind, op0, op1, op2) |
| `@lir_bb` | 各 lir_id の所属 BB |
| `@lir_machine_code` | encode 済み 32bit 機械語 |

詳細レイアウトは [hir.md](hir.md) / [lir.md](lir.md)。
