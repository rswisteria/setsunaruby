module Setsunaruby
  module TokenKind
    INT      = :int
    IDENT    = :ident
    KW_PUTS  = :kw_puts
    KW_TRUE  = :kw_true
    KW_FALSE = :kw_false
    KW_NIL   = :kw_nil
    KW_IF    = :kw_if
    KW_ELSIF = :kw_elsif
    KW_ELSE  = :kw_else
    KW_END   = :kw_end
    KW_WHILE  = :kw_while
    KW_THEN   = :kw_then
    KW_DEF    = :kw_def
    KW_RETURN = :kw_return
    KW_DO     = :kw_do     # `do ... end` ブロック開始 (Stage 3c.1)
    KW_YIELD  = :kw_yield  # `yield` (Stage 3c.2)
    KW_CLASS  = :kw_class  # `class` (Stage 3d.1)
    KW_SELF   = :kw_self   # `self` (Stage 3d.1)
    KW_BEGIN   = :kw_begin   # `begin` (Stage 3e)
    KW_RESCUE  = :kw_rescue  # `rescue` (Stage 3e)
    KW_ENSURE  = :kw_ensure  # `ensure` (Stage 3e)
    KW_RAISE   = :kw_raise   # `raise` (Stage 3e)
    KW_SUPER   = :kw_super   # `super` (Stage 3d.5)
    KW_LOOP    = :kw_loop    # `loop` (Stage 4b 無限ループ = while true 構文糖)
    KW_BREAK   = :kw_break   # `break` (Stage 4b 最内側 loop/while を抜ける)
    KW_NEXT    = :kw_next    # `next` (Stage 4b 最内側 loop/while の先頭へ)
    HASH_ROCKET = :hash_rocket   # `=>` (Stage 3e: rescue Class => e の束縛)
    IVAR     = :ivar       # `@var` インスタンス変数 (Stage 3d.1)。int_value = (start<<16)|len (start は @ の次)
    STR      = :str        # 文字列リテラル (Stage 3a)。int_value = strlit_idx
    PLUS      = :plus
    MINUS    = :minus
    STAR     = :star
    SLASH    = :slash
    PERCENT  = :percent
    EQ       = :eq
    EQ_EQ    = :eq_eq
    LT       = :lt
    GT       = :gt
    LE       = :le
    GE       = :ge
    LSHIFT   = :lshift     # `<<` (Stage 3a で文字列追加。Stage 4a で Fixnum<<Fixnum も dispatch)
    SHR      = :shr        # `>>` (Stage 4a 整数右シフト)
    BAND     = :band       # `&`  (Stage 4a 整数 AND)
    BXOR     = :bxor       # `^`  (Stage 4a 整数 XOR)
    BNOT     = :bnot       # `~`  (Stage 4a 整数 NOT、単項)
    LAND     = :land       # `&&` (Stage 4a 短絡 AND)
    LOR      = :lor        # `||` (Stage 4a 短絡 OR)
    NOT      = :not        # `!`  (Stage 4a 否定、単項)
    NEQ      = :neq        # `!=` (Stage 4a 不等価)
    LPAREN   = :lparen
    RPAREN   = :rparen
    LBRACK   = :lbrack     # `[` (Stage 3b 配列リテラル/index アクセス)
    RBRACK   = :rbrack     # `]`
    LBRACE   = :lbrace     # `{` (Stage 3c.3 中括弧ブロック)
    RBRACE   = :rbrace     # `}`
    DOT      = :dot        # `.` (Stage 3b: 配列の length のみ。一般 method dispatch は Stage 3d)
    PIPE     = :pipe       # `|` (Stage 3c.1 ブロックパラメータ区切り)
    COMMA    = :comma
    NEWLINE  = :newline
    EOF      = :eof
  end
end

# spinel の名前空間プレフィックス処理が一部のコード生成パス (volatile 宣言など) で
# 落ちることがあるため、Token クラスはトップレベルに置いて C 名 sp_Token に揃える。
class Token
  attr_accessor :kind, :int_value, :str_value, :line

  def initialize(kind, int_value, str_value, line)
    @kind      = kind
    @int_value = int_value
    @str_value = str_value
    @line      = line
  end
end
