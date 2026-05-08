# LIR 仕様

LIR (Low-level IR) は HIR から下げられた、arm64 機械語 1:1 対応に近い表現。
`lib/setsunaruby/lir_opcodes.rb` の `module LirOp` で命令種別が定義されている。

各 LIR insn は (kind, op0, op1, op2) の 4 つ組として SoA で表現する。
オペランドは物理レジスタ番号 (0..31) または即値、jump target は target lir_id。

`LirOp` の値域は `0x01-0x50` で、`HirOp` (0x100+) と完全分離。

## SoA レイアウト

```
@lir_kind[lir_id]
@lir_op0[lir_id]
@lir_op1[lir_id]
@lir_op2[lir_id]
@lir_bb[lir_id]            # 所属 BB
@lir_machine_code[lir_id]  # encode 済み 32bit 機械語
```

## LIR 命令一覧

### MOV (0x01-0x02)

| LirOp | hex | フィールド | arm64 |
|---|---|---|---|
| `MOV_IMM` | 0x01 | op0 = dst reg, op1 = 16bit 即値 | MOVZ Xd, #imm |
| `MOV_REG` | 0x02 | op0 = dst reg, op1 = src reg | ORR Xd, XZR, Xm |

### 算術 (0x10-0x13)

| LirOp | hex | フィールド | arm64 |
|---|---|---|---|
| `ADD` | 0x10 | op0 = dst, op1 = lhs, op2 = rhs | ADD Xd, Xn, Xm |
| `SUB` | 0x11 | 同上 | SUB Xd, Xn, Xm |
| `MUL` | 0x12 | 同上 | MADD Xd, Xn, Xm, XZR |
| `SDIV` | 0x13 | 同上 | SDIV Xd, Xn, Xm |

### 比較・条件 (0x20-0x21)

| LirOp | hex | フィールド | arm64 |
|---|---|---|---|
| `CMP` | 0x20 | op0 = lhs reg, op1 = rhs reg | SUBS XZR, Xn, Xm |
| `TBZ` | 0x21 | op0 = src reg, op1 = bit number, op2 = target lir_id | TBZ Xt, #bit, label |

`TBZ` は Fixnum タグの LSB チェックに使う (LSB == 0 なら side_exit へジャンプ)。

### 分岐 (0x30-0x36)

| LirOp | hex | フィールド | arm64 |
|---|---|---|---|
| `B` | 0x30 | op0 = target lir_id | B label |
| `B_EQ` | 0x31 | 同上 | B.EQ label |
| `B_NE` | 0x32 | 同上 | B.NE label |
| `B_LT` | 0x33 | 同上 | B.LT label |
| `B_GT` | 0x34 | 同上 | B.GT label |
| `B_LE` | 0x35 | 同上 | B.LE label |
| `B_GE` | 0x36 | 同上 | B.GE label |

`HirOp::JUMP_IF_FALSE` の偽分岐は **比較種別ごとに B.cond を切り替える**:

| HIR 比較 | 偽分岐の B.cond |
|---|---|
| `FIXNUM_EQ` | B.NE |
| `FIXNUM_LT` | B.GE |
| `FIXNUM_GT` | B.LE |
| `FIXNUM_LE` | B.GT |
| `FIXNUM_GE` | B.LT |

### 関数呼び出し・復帰 (0x40-0x50)

| LirOp | hex | フィールド | arm64 |
|---|---|---|---|
| `BL` | 0x40 | op0 = callee method idx | BL label |
| `RET` | 0x50 | (なし) | RET (= RET X30) |

### Arm64Cond

B.cond 等で使う condition code。

| Cond | 値 |
|---|---|
| `EQ` | 0x0 |
| `NE` | 0x1 |
| `GE` | 0xA |
| `LT` | 0xB |
| `GT` | 0xC |
| `LE` | 0xD |

---

## HIR → LIR lowering (`pass_lower_to_lir`)

各 BB の HIR insn を順に LIR 変換。代表的なルール:

| HIR | LIR |
|---|---|
| `LoadParam slot=k` | `MOV_REG Xreg, X<k>` (引数レジスタからローカル reg へ) |
| `LoadConst INT n` | `MOV_IMM Xreg, #n` |
| `FixnumAdd v_lhs, v_rhs` | `ADD Xreg, Xlhs, Xrhs` |
| `FixnumSub` | `SUB` |
| `FixnumMul` | `MUL` |
| `FixnumDiv` | `SDIV` (剰余は MSUB 省略、ダンプで明示) |
| `FixnumLt` (に続く JumpIfFalse) | `CMP Xa, Xb` + `B_GE target` |
| `GuardFixnum v` | `TBZ Xv, #0, side_exit` (LSB が 0 なら Fixnum でない) |
| `Call m_idx(args...)` | 引数を X0..X7 に MOV_REG → `BL m_idx` → 戻り値 X0 |
| `Return v` | `MOV_REG X0, Xv` + `RET` |
| `Phi` (out-of-SSA) | BB 末尾の jump/return 直前に `MOV_REG` 挿入 |

### 素朴レジスタ割り当て

```ruby
hir_to_reg = 9 + (hir_id % 20)   # x9..x28 を循環、衝突許容
```

実機実行しないため衝突許容で OK。教育目的に「割当アルゴリズムが必要」を
感じられる素朴な実装。

### Out-of-SSA conversion

phi のコピーは BB 末尾の jump/return 直前に `MOV_REG` で挿入。critical edge split
は実装していないので while loop の phi は厳密には正しくないが、構造は読み取れる。

---

## arm64 エンコード (`pass_encode_arm64`)

ARM A64 ISA 仕様のビット並びで 32bit 機械語にエンコード。

| 命令 | ビット形式 (大まかに) |
|---|---|
| `MOVZ Xd, #imm` | `1 10 100101 hw imm16 Rd` |
| `ORR Xd, XZR, Xm` (= MOV_REG) | `1 01 01010 00 0 Rm 000000 11111 Rd` |
| `ADD Xd, Xn, Xm` | `1 00 01011 00 0 Rm 000000 Rn Rd` |
| `SUB Xd, Xn, Xm` | `1 10 01011 00 0 Rm 000000 Rn Rd` |
| `MADD Xd, Xn, Xm, XZR` (= MUL) | `1 0011011 000 Rm 0 11111 Rn Rd` |
| `SDIV Xd, Xn, Xm` | `1 0011010 110 Rm 0000 11 Rn Rd` |
| `SUBS XZR, Xn, Xm` (= CMP) | `1 11 01011 00 0 Rm 000000 Rn 11111` |
| `B label` | `0 00101 imm26` |
| `B.cond label` | `01010100 imm19 0 cond` |
| `BL label` | `1 00101 imm26` |
| `RET (= RET X30)` | `1101011 00 1 011111 000000 11110 00000` (= 0xd65f03c0) |
| `TBZ Xt, #bit, label` | `1 0110110 b40 imm14 Rt` (b5 = bit番号 上位 1 bit, b40 = 下位 5 bit) |

### TBZ の特殊性

`TBZ` (Test bit and Branch if Zero) の機械語は 64bit/32bit 切替・ビット位置の
分割エンコードがあるため `encode_tbz` ヘルパで個別処理。target = -1 (未解決) は
0 にクランプして imm14 汚染を防ぐ。

### 機械語ダンプの出力形式

```
mov x9, x0              ; 0xaa0003e9
cmp x26, x27            ; 0xeb1b035f
b.ge BB2                ; 0x5400004a
bl m1                   ; 0x94000000
ret                     ; 0xd65f03c0
```

GDB 風の `ニーモニック ; 0x...` 形式。BB 単位で表示。

---

## ダンプ全体例

```
ZJIT LIR for method idx=1:
  BB0:
    mov x9, x0          ; 0xaa0003e9   ← LoadParam slot=0
    mov x11, #5         ; 0xd28000ab   ← LoadConst 2
    cmp x26, x27        ; 0xeb1b035f   ← FixnumLt
    b.ge BB2            ; 0x5400004a   ← JumpIfFalse (FixnumLt の偽分岐 = B_GE)
    tbz x9, #0, side_exit ; 0xb6000009 ← GuardFixnum
    tbz x11, #0, side_exit; 0xb600000b
  BB1:
    b BB3               ; 0x14000003
  BB2:
    sub x18, x28, x9    ; 0xcb090392   ← FixnumSub (n - 1)
    mov x0, x18         ; 0xaa1203e0
    bl m1               ; 0x94000000   ← fib(n - 1)
    ...
    add x24, x12, x13   ; 0x8b0d0198
  BB3:
    mov x0, x24         ; 0xaa1803e0
    ret                 ; 0xd65f03c0
```
