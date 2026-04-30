module Setsunaruby
  module TokenKind
    INT      = :int
    IDENT    = :ident
    KW_PUTS  = :kw_puts
    KW_TRUE  = :kw_true
    KW_FALSE = :kw_false
    KW_NIL   = :kw_nil
    PLUS     = :plus
    MINUS    = :minus
    STAR     = :star
    SLASH    = :slash
    PERCENT  = :percent
    EQ_EQ    = :eq_eq
    LT       = :lt
    GT       = :gt
    LE       = :le
    GE       = :ge
    LPAREN   = :lparen
    RPAREN   = :rparen
    NEWLINE  = :newline
    EOF      = :eof
  end
end

# spinel の名前空間プレフィックス処理が一部のコード生成パス (volatile 宣言など) で
# 落ちることがあるため、Token クラスはトップレベルに置いて名前を一致させる。
class Token
  attr_accessor :kind, :int_value, :str_value, :line

  def initialize(kind, int_value, str_value, line)
    @kind      = kind
    @int_value = int_value
    @str_value = str_value
    @line      = line
  end
end
