# HIR 仕様

HIR (High-level IR) はホットメソッドの bytecode を SSA 形式で持ち上げた中間表現。
`lib/setsunaruby/hir_opcodes.rb` の `module HirOp` で命令種別が定義されている。

`HirOp` の値域は `Op::` (bytecode) と被らない **0x100 以上** にしてある (spinel の
whole-program 推論で同値の異モジュール定数が混同されるリスクを避けるため)。

## SoA レイアウト

1 命令 = (kind, op0, op1, op2) の 4 つ組。HIR insn の id は `hir_id`
(= `@hir_kind` の index)。

```
@hir_kind[hir_id]    # HirOp の値 (0x101-0x1A5)
@hir_op0[hir_id]     # 命令種別ごとに意味が変わる
@hir_op1[hir_id]
@hir_op2[hir_id]
@hir_call_args       # CALL / ARRAY_NEW 等の可変長引数 (hir_id の flat 列)
@hir_phi_args        # phi の (BB, value) ペアを flat に保持
@hir_deleted[hir_id] # 1 なら DCE 削除済み
@hir_bb[hir_id]      # 所属 BB id
@hir_rename_target[hir_id]  # SSA rename で reaching def に redirect
@hir_bc_pc[hir_id]   # 出処 bytecode PC (プロファイル参照用)
```

## HIR 命令一覧

### 値ロード・スタック制御 (0x100 系)

| HirOp | hex | フィールド | 意味 |
|---|---|---|---|
| `LOAD_CONST` | 0x101 | op0 = HirConstTag, op1 = INT のとき raw 値 | `nil`/`false`/`true`/`int` を読み込む |
| `LOAD_LOCAL` | 0x102 | op0 = slot idx | (rename 後は deleted=1、reaching def に redirect) |
| `STORE_LOCAL` | 0x103 | op0 = slot idx, op1 = value hir_id | (rename 後は deleted=1) |
| `POP` | 0x105 | (なし) | jump target 解決用に bc アドレスを占有 |
| `PHI` | 0x106 | op0 = slot, op1 = phi_args 開始 idx, op2 = pred 数 | SSA 合流点 |
| `LOAD_PARAM` | 0x107 | op0 = slot idx | パラメータの初期 reaching def (BB0 先頭) |
| `JUMP` | 0x108 | op0 = target hir_id | 無条件分岐 |
| `JUMP_IF_FALSE` | 0x109 | op0 = cond, op1 = target | 条件分岐 |

### 二項算術・比較 (0x110-0x124)

| HirOp | hex | 意味 |
|---|---|---|
| `ADD` `SUB` `MUL` `DIV` `MOD` | 0x110-0x114 | op0 = lhs hir_id, op1 = rhs hir_id |
| `EQ` `LT` `GT` `LE` `GE` | 0x120-0x124 | 同上 |

### I/O・関数 (0x130-0x141)

| HirOp | hex | 意味 |
|---|---|---|
| `PUTS` | 0x130 | op0 = value hir_id |
| `CALL` | 0x140 | op0 = method_idx, op1 = `@hir_call_args` 内の args_start, op2 = arity |
| `RETURN` | 0x141 | op0 = value hir_id |

### 型特化 (0x150-0x174)

| HirOp | hex | 意味 |
|---|---|---|
| `GUARD_FIXNUM` | 0x150 | op0 = guarded value hir_id (Fixnum でなければ side exit) |
| `FIXNUM_ADD/SUB/MUL/DIV/MOD` | 0x160-0x164 | Fixnum 入力前提の特化命令 |
| `FIXNUM_EQ/LT/GT/LE/GE` | 0x170-0x174 | 同上 (比較) |

### 文字列・配列 (0x180-0x185)

LIR に lower しない (HIR ダンプとプロファイル経路の整合のみ目的)。

| HirOp | hex | 意味 |
|---|---|---|
| `LOAD_STR` | 0x180 | op0 = strlit_idx |
| `LSHIFT` | 0x181 | op0 = lhs hir_id, op1 = rhs hir_id (String/Array 多相) |
| `ARRAY_NEW` | 0x182 | op0 = size, op1 = args_start, op2 = size 再掲 |
| `ARRAY_GET` | 0x183 | op0 = arr, op1 = idx |
| `ARRAY_SET` | 0x184 | op0 = arr, op1 = idx, op2 = val |
| `ARRAY_LEN` | 0x185 | op0 = arr |

### ブロック / yield (0x190-0x193)

LIR に lower しない。

| HirOp | hex | 意味 |
|---|---|---|
| `CALL_WITH_BLOCK` | 0x190 | op0 = method_idx, op1 = args_start, op2 = arity |
| `YIELD` | 0x191 | op0 = argc, op1 = args_start |
| `BLOCK_RETURN` | 0x192 | op0 = value hir_id |
| `BLOCK_GIVEN_P` | 0x193 | (なし) |

### クラス関連 (0x1A0-0x1A5)

LIR に lower しない。

| HirOp | hex | 意味 |
|---|---|---|
| `INSTANCE_NEW` | 0x1A0 | op0 = class_idx |
| `CALL_METHOD` | 0x1A1 | op0 = name_packed, op1 = args_start (含む receiver), op2 = argc |
| `LOAD_SELF` | 0x1A2 | (なし) |
| `LOAD_IVAR` | 0x1A3 | op0 = ivar_slot |
| `STORE_IVAR` | 0x1A4 | op0 = ivar_slot, op1 = value hir_id |
| `DUP` | 0x1A5 | op0 = value hir_id (= sstack 上は同じ hir_id を再 push) |

### HirConstTag

`LOAD_CONST` の op0 タグ。op1 に意味のある値が入るのは INT のみ。

| Tag | 値 |
|---|---|
| `NIL` | 0 |
| `FALSE` | 1 |
| `TRUE` | 2 |
| `INT` | 3 |

---

## bytecode → HIR 変換 (`build_hir`)

ホット method の `@bytecode[begin_pc...end_pc]` を順に走査し、stack-based VM
を simulate する形で HIR insn を emit する。具体的には:

1. **シンボリックスタック (sstack)** を持ち、bytecode の push/pop を模倣
2. 各 bytecode opcode に対応する HirOp insn を emit して `hir_id` を sstack に push
3. JUMP/JUMP_IF_FALSE の target は emit 時点で未確定 → 後で patch up
4. 全パス完了後、bc → hir_id の写像 `@bc_to_hir` を使って patch を解決

`@hir_bc_pc[hir_id]` に出処 bc PC を記録しておくことで、JIT-3c の型プロファイル
参照で「この HIR insn がどの bc PC のときに観測されたか」を逆引きできる。

---

## 最適化パス

### pass_fold_constants (JIT-3a)

forward sweep 1 パス。両 op が `LOAD_CONST(INT)` の二項算術 / 比較を畳み込み、
in-place で `LOAD_CONST` に書き換える。連鎖畳み込みも 1 パスで完結
(`1 + 2 * 3 - 4 = 3` が一気に畳まれる)。

`DIV` / `MOD` は b ≠ 0 のみ畳み込み (ZeroDivisionError を保つ)。

### pass_eliminate_dead_code (JIT-3a)

副作用なし & use 数 0 の insn に `deleted = 1` をセット。jump target も use として
数えるため jump 先の insn は守られる。`DIV/MOD` は折り畳まれずに残った場合の
raise を保つため副作用あり扱い。

### pass_build_cfg (JIT-3b1) {#cfg}

JUMP / JUMP_IF_FALSE / RETURN を境界に basic block を分割。`@bb_first_insn` /
`@bb_last_insn` / `@bb_succ0` / `@bb_succ1` / `@hir_bb` を構築。
JUMP_IF_FALSE は succ0 = 偽分岐、succ1 = 真分岐。

### pass_clean_cfg (JIT-3b1)

エントリ BB から到達不能な BB を BFS で除去。`@bb_idom` を -1 にしたまま残し、
ダンプ時にスキップする方式。

### pass_compute_dom (JIT-3b2) {#dominator}

iterative dominator algorithm (Cooper et al. の素朴版)。BB 数が小さいので O(N^3) で
問題なし。`dom_intersect` は素朴 LCA。

### pass_compute_df (JIT-3b2)

Cytron の式: 合流点 b について各 pred から `idom(b)` まで遡って `DF[runner].add(b)`。
フラグ matrix で集計してから flat 配列 (`@bb_df_*`) に変換。

### pass_insert_phis (JIT-3b3) {#ssa}

各 slot ごとに「def 集合 → DF を辿って phi 挿入 → phi 自身が新たな def」を
worklist で反復。`phi_at_bb` フラグ matrix で重複挿入防止。

### pass_rename_vars (JIT-3b3)

dominator tree DFS で `reaching_top` + `saved_stack` を維持。

- `LOAD_LOCAL` → `@hir_rename_target` に reaching def の hir_id を記録、`deleted = 1` に
- `STORE_LOCAL` → op1 を resolve_rename して reaching_top に push、`deleted = 1` に
- 後継 BB の phi に args を埋める (`fill_phi_args_for_succ`)

最後に `apply_rename_targets` で全 use を `resolve_rename` で置換。

### pass_type_specialize (JIT-3c) {#型特化}

`pass_rename_vars` の後 (= 完全 SSA 化済み HIR) に走る。

- VM の `exec_arith` / `exec_compare` / `exec_eq` が **Fixnum 確定後** に
  `@profile_fixnum_pc[bc_pc]` フラグを立てる
- `pass_type_specialize` で各 HIR insn を `@hir_bc_pc[hir_id]` から逆引きして
  プロファイル参照
- 観測された場合: op0/op1 を `GUARD_FIXNUM` の hir_id に書き換え、kind を
  `FIXNUM_ADD` / `FIXNUM_LT` 等の特化版に
- 観測されなければ generic のまま残留 (= プロファイル収集の機能の証明)

---

## ダンプ形式

```
ZJIT HIR (raw) for method idx=N:
  BB0:
    v0 = LoadParam slot=0
    v1 = LoadConst 2
    v2 = Lt v0, v1
    v3 = JumpIfFalse v2, BB2
  ...

ZJIT HIR (optimized) for method idx=N:
  BB0:
    v17 = GuardFixnum v0
    v18 = GuardFixnum v1
    v3 = FixnumLt v17, v18
    ...
  BB3 (preds: BB1, BB2):
    v15 = Return v14

ZJIT CFG analysis for method idx=N:
  BB0: idom=BB0, DF={}
  BB1: idom=BB0, DF={BB3}
  BB2: idom=BB0, DF={BB3}
  BB3: idom=BB0, DF={}
```
