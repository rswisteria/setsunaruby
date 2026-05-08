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
    # Stage 4a: `||` 短絡用に「stack-top が真ならジャンプ」。JUMP_IF_FALSE と対称、
    # cond は pop する (JUMP_IF_FALSE と同じ仕様)。
    JUMP_IF_TRUE   = 0x0A   # operand: 3-byte fixed-width SLEB128 offset

    ADD = 0x10
    SUB = 0x11
    MUL = 0x12
    DIV = 0x13
    MOD = 0x14

    # Stage 4a: 整数のビット演算 (Fixnum × Fixnum を要求)。
    # SHL は LSHIFT (0x43) と区別される「整数限定」のシフト。compiler は `<<` ソースに対して
    # 多態の LSHIFT を emit するため SHL は現状未使用 (将来の JIT 特化用に予約)。
    SHL  = 0x15
    SHR  = 0x16
    BAND = 0x17
    BOR  = 0x18
    BXOR = 0x19
    BNOT = 0x1A   # 単項

    EQ = 0x20
    LT = 0x21
    GT = 0x22
    LE = 0x23
    GE = 0x24
    # Stage 4a: EQ / 真偽の補完。NEQ は EQ の反転 (型違い OK)、NOT は truthy 値の反転。
    NEQ = 0x25
    NOT = 0x26    # 単項

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

    # Stage 3d.2: スタック top を 1 つ複製。Foo.new(args) の compile-time 展開で
    # INSTANCE_NEW 後の instance を残しつつ initialize 呼び出しの receiver にも使うため。
    DUP = 0x52

    # Stage 3e: 例外処理。
    # PUSH_HANDLER は begin の入口で例外ハンドラを登録 (現在の stack/cfp/yield depth を記録)。
    # operand = catch_rel (3-byte SLEB)。ensure には catch_pc から rescue chain を fall-through
    # して自然到達するため別 operand は不要 (rescue なし=ensure-only の場合は catch_pc を ensure 先頭に向ける)。
    # POP_HANDLER は本体が例外なく抜けた時にハンドラを 1 つ取り除く。
    # RAISE は stack top を pop してそれを例外として handler stack まで unwind する。
    # LOAD_EXCEPTION / CLEAR_EXCEPTION は rescue chain で @exception を読み書きする。
    # CHECK_EXCEPTION_CLASS は operand の class_idx (または継承先) と一致するか bool で push。
    # operand=-1 は catch-all (`rescue` クラス指定なし) 用センチネル。
    # RERAISE_OR_END は ensure 末尾。@exception が残っていれば再 unwind、なければ次へ流す。
    PUSH_HANDLER          = 0x53   # operand: catch_rel(3-byte)
    POP_HANDLER           = 0x54
    RAISE                 = 0x55
    LOAD_EXCEPTION        = 0x56
    CLEAR_EXCEPTION       = 0x57
    CHECK_EXCEPTION_CLASS = 0x58   # operand: SLEB128 class_idx (-1 = catch-all)
    RERAISE_OR_END        = 0x59

    # Stage 3d.5: `super` 呼び出し。受信者は @cur_self、検索は現在 method の defining class の
    # 親 chain から始まる (= 自分自身は skip)。
    # operand: SLEB128 name_packed (= 現在 method の name)、SLEB128 argc。
    # スタックには CALL_SUPER 命令直前に self → args の順で push 済みである必要がある。
    CALL_SUPER            = 0x5A

    HALT = 0xFF
  end
end
