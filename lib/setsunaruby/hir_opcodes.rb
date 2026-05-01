module Setsunaruby
  # JIT-2: HIR (High-level IR, lite SSA) の命令種別。
  # SoA (`@hir_kind/op0/op1/op2`) で 1 命令 = (kind, op0, op1, op2) の 4 つ組。
  # 値域は Op:: と被らない 0x100+ にしてある (spinel の whole-program 推論で
  # 同値の異モジュール定数が混同されるリスクを避けるため)。
  # 値域は 0x100 単位でグルーピング (0x100 系=値ロード/スタック制御、
  # 0x110/0x120=二項演算、0x130/0x140=I/O・関数)。空番は将来の同系列追加用に予約。
  module HirOp
    LOAD_CONST    = 0x101   # op0 = HirConstTag, op1 = INT のとき raw 整数値
    LOAD_LOCAL    = 0x102   # op0 = slot idx (JIT-3b3 rename で deleted=1 化、@hir_rename_target で reaching def に redirect)
    STORE_LOCAL   = 0x103   # op0 = slot idx, op1 = value (hir_id) (JIT-3b3 rename で deleted=1 化)
    POP           = 0x105   # 引数なし。jump target 解決用に bc アドレスを占有する
    PHI           = 0x106   # op0 = slot, op1 = phi_args の start_idx, op2 = pred 数
    LOAD_PARAM    = 0x107   # op0 = slot idx (メソッドパラメータの初期 reaching def)
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
    RETURN = 0x141

    # Stage 3a/3b: 文字列・配列。LIR への lower はせず、HIR ダンプとプロファイル経路の整合のみ目的。
    LOAD_STR = 0x180        # op0 = strlit_idx
    LSHIFT   = 0x181        # op0 = lhs (hir_id), op1 = rhs (hir_id) — String/Array 多相

    # Stage 3b: 配列。
    ARRAY_NEW = 0x182       # op0 = size, op1 = args_start (in @hir_call_args), op2 = size 再掲
    ARRAY_GET = 0x183       # op0 = arr (hir_id), op1 = idx (hir_id)
    ARRAY_SET = 0x184       # op0 = arr (hir_id), op1 = idx (hir_id), op2 = val (hir_id)
    ARRAY_LEN = 0x185       # op0 = arr (hir_id)

    # Stage 3c.2: ブロック付き呼び出しと yield。LIR には lower しない。
    CALL_WITH_BLOCK = 0x190   # op0 = method_idx, op1 = args_start, op2 = arity
    YIELD           = 0x191   # op0 = argc, op1 = args_start
    BLOCK_RETURN    = 0x192   # op0 = value (hir_id)

    # JIT-3c: 型特化命令。GUARD_FIXNUM は値が Fixnum でなければ side exit。
    # FIXNUM_* は Fixnum 入力前提で動作する特化命令。
    GUARD_FIXNUM = 0x150    # op0 = guarded value (hir_id)
    FIXNUM_ADD = 0x160      # op0 = lhs (hir_id, GuardFixnum 経由), op1 = rhs (同)
    FIXNUM_SUB = 0x161
    FIXNUM_MUL = 0x162
    FIXNUM_DIV = 0x163
    FIXNUM_MOD = 0x164

    FIXNUM_EQ = 0x170
    FIXNUM_LT = 0x171
    FIXNUM_GT = 0x172
    FIXNUM_LE = 0x173
    FIXNUM_GE = 0x174
  end

  # LOAD_CONST のタグ。op1 に意味のある値が入るのは INT のみ。
  module HirConstTag
    NIL   = 0
    FALSE = 1
    TRUE  = 2
    INT   = 3
  end
end
