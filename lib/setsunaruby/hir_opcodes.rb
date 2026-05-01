module Setsunaruby
  # JIT-2: HIR (High-level IR, lite SSA) の命令種別。
  # SoA (`@hir_kind/op0/op1/op2`) で 1 命令 = (kind, op0, op1, op2) の 4 つ組。
  # 値域は Op:: と被らない 0x100+ にしてある (spinel の whole-program 推論で
  # 同値の異モジュール定数が混同されるリスクを避けるため)。
  module HirOp
    LOAD_CONST    = 0x101   # op0 = HirConstTag, op1 = INT のとき raw 整数値
    LOAD_LOCAL    = 0x102   # op0 = slot idx
    STORE_LOCAL   = 0x103   # op0 = slot idx, op1 = value (hir_id)
    POP           = 0x105   # 引数なし。jump target 解決用に bc アドレスを占有する
    JUMP          = 0x108   # op0 = target hir_id
    JUMP_IF_FALSE = 0x109   # op0 = cond (hir_id), op1 = target hir_id

    ADD = 0x110             # op0 = lhs (hir_id), op1 = rhs (hir_id)
    SUB = 0x111
    MUL = 0x112
    DIV = 0x113
    MOD = 0x114

    EQ = 0x120
    LT = 0x121
    GT = 0x122
    LE = 0x123
    GE = 0x124

    PUTS   = 0x130          # op0 = value (hir_id)
    CALL   = 0x140          # op0 = method_idx, op1 = args_start (in @hir_call_args), op2 = arity
    RETURN = 0x141          # op0 = value (hir_id)
  end

  # LOAD_CONST のタグ。op1 に意味のある値が入るのは INT のみ。
  module HirConstTag
    NIL   = 0
    FALSE = 1
    TRUE  = 2
    INT   = 3
  end
end
