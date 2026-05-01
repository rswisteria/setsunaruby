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
    LSHIFT   = :lshift     # `<<` (Stage 3a で文字列追加)
    LPAREN   = :lparen
    RPAREN   = :rparen
    LBRACK   = :lbrack     # `[` (Stage 3b 配列リテラル/index アクセス)
    RBRACK   = :rbrack     # `]`
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
