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
    HALT = 0xFF
  end
end
