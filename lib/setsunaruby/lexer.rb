require_relative 'token'

module Setsunaruby
  class Lexer
    # ASCII コード定数 (spinel が "\n" などの単一文字リテラル比較を C ソースに
    # 生のまま埋め込んでしまうため、整数比較に統一する)
    NL    = 10
    TAB   =  9
    SP    = 32
    HASH  = 35
    LP    = 40
    RP    = 41
    STAR  = 42
    PLUS  = 43
    MINUS = 45
    SLASH = 47
    PCT   = 37
    EQ    = 61
    LT    = 60
    GT    = 62
    UND   = 95
    D0    = 48
    D9    = 57
    A_LC  = 97
    Z_LC  = 122
    A_UC  = 65
    Z_UC  = 90

    KEYWORDS = ['puts', 'true', 'false', 'nil'].freeze

    def initialize(src)
      @src   = src
      @bytes = src.bytes
      @pos   = 0
      @line  = 1
    end

    def tokenize
      tokens = []
      while @pos < @bytes.length
        b = @bytes[@pos]
        if b == SP || b == TAB
          @pos += 1
        elsif b == NL
          tokens.push(Token.new(TokenKind::NEWLINE, @line))
          @line += 1
          @pos += 1
        elsif b == HASH
          @pos += 1
          while @pos < @bytes.length && @bytes[@pos] != NL
            @pos += 1
          end
        elsif digit?(b)
          tokens.push(read_number)
        elsif ident_start?(b)
          tokens.push(read_ident_or_keyword)
        else
          tokens.push(read_punct(b))
        end
      end
      tokens.push(Token.new(TokenKind::EOF, @line))
      tokens
    end

    private

    def digit?(b)
      b >= D0 && b <= D9
    end

    def ident_start?(b)
      (b >= A_LC && b <= Z_LC) || (b >= A_UC && b <= Z_UC) || b == UND
    end

    def ident_cont?(b)
      ident_start?(b) || digit?(b)
    end

    def read_number
      n = 0
      while @pos < @bytes.length && digit?(@bytes[@pos])
        n = n * 10 + (@bytes[@pos] - D0)
        @pos += 1
      end
      t = Token.new(TokenKind::INT, @line)
      t.int_value = n
      t
    end

    def read_ident_or_keyword
      # 識別子は ASCII のみ。バイト列から直接 String を組み立てる。
      # (@src[start, len] は文字位置スライスなのでマルチバイトコメントが
      #  混在するとズレる)
      name = ""
      while @pos < @bytes.length && ident_cont?(@bytes[@pos])
        name << @bytes[@pos].chr
        @pos += 1
      end
      if KEYWORDS.include?(name)
        t = Token.new(TokenKind::KW, @line)
        t.str_value = name
        t
      else
        t = Token.new(TokenKind::IDENT, @line)
        t.str_value = name
        t
      end
    end

    def read_punct(b)
      if b == PLUS
        @pos += 1
        Token.new(TokenKind::PLUS, @line)
      elsif b == MINUS
        @pos += 1
        Token.new(TokenKind::MINUS, @line)
      elsif b == STAR
        @pos += 1
        Token.new(TokenKind::STAR, @line)
      elsif b == SLASH
        @pos += 1
        Token.new(TokenKind::SLASH, @line)
      elsif b == PCT
        @pos += 1
        Token.new(TokenKind::PERCENT, @line)
      elsif b == LP
        @pos += 1
        Token.new(TokenKind::LPAREN, @line)
      elsif b == RP
        @pos += 1
        Token.new(TokenKind::RPAREN, @line)
      elsif b == EQ
        if @pos + 1 < @bytes.length && @bytes[@pos + 1] == EQ
          @pos += 2
          Token.new(TokenKind::EQ_EQ, @line)
        else
          raise "Lexer error: line #{@line}: '=' alone is not valid in Stage 0"
        end
      elsif b == LT
        if @pos + 1 < @bytes.length && @bytes[@pos + 1] == EQ
          @pos += 2
          Token.new(TokenKind::LE, @line)
        else
          @pos += 1
          Token.new(TokenKind::LT, @line)
        end
      elsif b == GT
        if @pos + 1 < @bytes.length && @bytes[@pos + 1] == EQ
          @pos += 2
          Token.new(TokenKind::GE, @line)
        else
          @pos += 1
          Token.new(TokenKind::GT, @line)
        end
      else
        raise "Lexer error: line #{@line}: unexpected byte #{b}"
      end
    end
  end
end
