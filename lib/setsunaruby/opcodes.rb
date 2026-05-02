module Setsunaruby
  module Op
    PUSH_INT       = 0x01
    PUSH_TRUE      = 0x02
    PUSH_FALSE     = 0x03
    PUSH_NIL       = 0x04

    POP            = 0x05
    STORE_LOCAL    = 0x06   # operand: SLEB128 idx (variable-length)
    LOAD_LOCAL     = 0x07   # operand: SLEB128 idx (variable-length)
    JUMP           = 0x08   # operand: 3-byte fixed-width SLEB128 offset
    JUMP_IF_FALSE  = 0x09   # operand: 3-byte fixed-width SLEB128 offset

    ADD = 0x10
    SUB = 0x11
    MUL = 0x12
    DIV = 0x13
    MOD = 0x14

    EQ = 0x20
    LT = 0x21
    GT = 0x22
    LE = 0x23
    GE = 0x24

    PUTS = 0x30

    CALL   = 0x40   # operand: SLEB128 method_idx
    RETURN = 0x41

    # Stage 3a: 文字列。
    # PUSH_STR は実行時に毎回新しいヒープ String を確保する (Ruby のリテラル独立性)。
    # LSHIFT は <<: 両辺 String なら relocate-and-grow で in-place 拡張、Array なら push (Stage 3b)。
    # 多相 dispatch は VM 側で receiver の heap kind に応じて行う。
    PUSH_STR   = 0x42   # operand: SLEB128 strlit_idx
    LSHIFT     = 0x43

    # Stage 3b: 配列。
    # ARRAY_NEW は size 個のスタック上要素を pop して新しい heap Array を確保する。
    # ARRAY_GET / ARRAY_SET は a[i] / a[i]=v、ARRAY_LEN は a.length。
    ARRAY_NEW = 0x44    # operand: SLEB128 size
    ARRAY_GET = 0x45
    ARRAY_SET = 0x46
    ARRAY_LEN = 0x47

    # Stage 3c.2: 一般ブロック付きメソッド呼び出しと yield。
    # CALL_WITH_BLOCK は CALL と同じだが、メソッドフレームに block_pc と block_arity を
    # 関連付ける。block_arity は yield argc とのランタイム不一致を検出するため。
    # YIELD は現在のフレームの block_pc に飛び、引数を caller's scope へ渡す。
    # BLOCK_RETURN は block の終端、yield の続きへ復帰する。
    CALL_WITH_BLOCK = 0x48   # operands: SLEB128 method_idx, SLEB128 block_pc, SLEB128 block_arity
    YIELD           = 0x49   # operand: SLEB128 argc
    BLOCK_RETURN    = 0x4A

    # Stage 3c.3: 現フレームにブロックが紐付いているかを true/false で push する組み込み。
    BLOCK_GIVEN_P   = 0x4B

    # Stage 3d.1: クラス。
    # INSTANCE_NEW は class_idx に対応するインスタンスを 1 つ確保 (ivar 全 NIL_VAL 初期化)。
    # CALL_METHOD は受信者の class を見て name で method を解決し、self 付きで呼び出す。
    # LOAD_SELF / LOAD_IVAR / STORE_IVAR は method 内部用。
    INSTANCE_NEW    = 0x4C   # operand: SLEB128 class_idx
    CALL_METHOD     = 0x4D   # operands: SLEB128 name_packed, SLEB128 argc
    LOAD_SELF       = 0x4E
    LOAD_IVAR       = 0x4F   # operand: SLEB128 ivar_slot
    STORE_IVAR      = 0x50   # operand: SLEB128 ivar_slot
    CALL_METHOD_WITH_BLOCK = 0x51   # operands: name_packed, argc, block_pc, block_arity

    HALT = 0xFF
  end
end
