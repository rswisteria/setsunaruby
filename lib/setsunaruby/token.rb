module Setsunaruby
  module TokenKind
    INT     = :int
    IDENT   = :ident
    KW      = :kw
    PLUS    = :plus
    MINUS   = :minus
    STAR    = :star
    SLASH   = :slash
    PERCENT = :percent
    EQ_EQ   = :eq_eq
    LT      = :lt
    GT      = :gt
    LE      = :le
    GE      = :ge
    LPAREN  = :lparen
    RPAREN  = :rparen
    NEWLINE = :newline
    EOF     = :eof
  end

  # spinel が単一型推論できるよう、フィールド型を固定する。
  # 値の意味は kind で決まる:
  #   INT 以外なら int_value は 0
  #   IDENT/KW 以外なら str_value は ""
  #
  # Note: spinel の `def self.xxx` 型推論バグ回避のため factory method は持たない。
  # 構築は呼び出し元でインライン化する (n = Token.new(...); n.field = ...)。
  class Token
    attr_accessor :kind, :int_value, :str_value, :line

    def initialize(kind, line)
      @kind      = kind
      @int_value = 0
      @str_value = ""
      @line      = line
    end
  end
end
