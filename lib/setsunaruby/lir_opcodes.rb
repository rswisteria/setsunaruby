module Setsunaruby
  # JIT-4 (案 A): LIR (Low-level IR) の命令種別。
  # HIR から下げられた、arm64 機械語 1:1 対応に近い表現。
  # 各 LIR insn は (kind, op0, op1, op2) の 4 つ組として SoA で表現する。
  # オペランドは物理レジスタ番号 (0..31) または即値、jump target は target lir_id。
  module LirOp
    MOV_IMM = 0x01     # op0 = dst reg, op1 = 16bit 即値 (MOVZ)
    MOV_REG = 0x02     # op0 = dst reg, op1 = src reg (= ORR Rd, XZR, Rm)

    # JIT-4c x86_64: arch 中立な引数/戻り値 MOV。arm64 と x86_64 で arg/return
    # register 規約が異なるため汎用 MOV_REG とは別に持つ。arm64 では MOV_REG と
    # 同じ encode に落ちる。x86_64 (SysV AMD64) では arg slot を RDI/RSI/RDX/RCX/
    # R8/R9 に、return を RAX にマップする。
    MOV_FROM_ARG = 0x03   # op0 = dst reg, op1 = arg slot (0..7)
    MOV_TO_ARG   = 0x04   # op0 = arg slot, op1 = src reg
    # NOTE: 他の LirOp と異なり op0 が src。dst は暗黙の戻り値レジスタ。
    MOV_TO_RET   = 0x05   # op0 = src reg, dst は arch ごとに固定の戻り値 reg

    ADD  = 0x10        # op0 = dst reg, op1 = lhs reg, op2 = rhs reg
    SUB  = 0x11
    MUL  = 0x12
    SDIV = 0x13

    CMP  = 0x20        # op0 = lhs reg, op1 = rhs reg (= SUBS XZR, Xn, Xm)
    TBZ  = 0x21        # op0 = src reg, op1 = bit number, op2 = target lir_id

    B    = 0x30        # op0 = target lir_id
    B_EQ = 0x31
    B_NE = 0x32
    B_LT = 0x33
    B_GT = 0x34
    B_LE = 0x35
    B_GE = 0x36

    BL   = 0x40        # op0 = callee method idx (= function label のプレースホルダ)
    RET  = 0x50        # 引数なし (x30 から戻る)
  end

  # arm64 condition code (B.cond / SET 等で使う)
  module Arm64Cond
    EQ = 0x0
    NE = 0x1
    GE = 0xA
    LT = 0xB
    GT = 0xC
    LE = 0xD
  end
end
