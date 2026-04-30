require_relative 'token'
require_relative 'ast'
require_relative 'opcodes'
require_relative 'object'

module Setsunaruby
  # Lexer / Parser / Compiler / VM を統合した1パス実行器。
  #
  # 設計理由: spinel の whole-program 型推論は、Token / ASTNode のような
  # ユーザクラスの配列 (PtrArray) を保持すると instance variable の型が
  # sp_RbVal (poly) に決め打ちされ、下流のメソッドの型推論が連鎖的に崩壊
  # して segfault に至る。
  #
  # 解決策: 中間配列を持たないストリーミング処理。
  #   - tokenize → parse: 単一の lookahead Token (@cur_token) のみ保持
  #   - parse → compile: parse_statement が返した ASTNode を即 compile_statement へ
  #   - compile → vm: 全 statement を compile し終わってから run
  # 結果として残る配列は @bytecode (IntArray) と @stack (IntArray) のみで、
  # spinel の型推論が安定する。
  class Interp
    # ---- ASCII コード定数 (Lexer 用) ----
    NL    = 10
    TAB   =  9
    SP    = 32
    HASH  = 35
    LP    = 40
    RP    = 41
    STAR_BYTE  = 42
    PLUS_BYTE  = 43
    MINUS_BYTE = 45
    SLASH_BYTE = 47
    PCT   = 37
    EQ    = 61
    LT_BYTE = 60
    GT_BYTE = 62
    UND   = 95
    D0    = 48
    D9    = 57
    A_LC  = 97
    Z_LC  = 122
    A_UC  = 65
    Z_UC  = 90

    KW_PUTS_BYTES  = [112, 117, 116, 115].freeze
    KW_TRUE_BYTES  = [116, 114, 117, 101].freeze
    KW_FALSE_BYTES = [102, 97, 108, 115, 101].freeze
    KW_NIL_BYTES   = [110, 105, 108].freeze

    def initialize
      @src       = ""
      @bytes     = []
      @lex_pos   = 0
      @line      = 1
      @cur_token = nil          # lookahead 1
      @bytecode  = []           # IntArray
      @stack     = []           # IntArray
      @pc        = 0
    end

    def run_file(path)
      run_string(File.read(path))
    end

    def run_string(src)
      @src      = src
      @bytes    = src.bytes
      @lex_pos  = 0
      @line     = 1
      @bytecode = []
      @stack    = []
      @pc       = 0

      # 最初のトークンを先読み
      @cur_token = next_token
      # parse and compile in one pass
      while !at_end?
        skip_newlines
        if at_end?
          break
        end
        stmt = parse_statement
        consume_terminator
        compile_statement(stmt)
      end
      @bytecode.push(Op::HALT)
      run_vm
      nil
    end

    # ============================================================
    # Lexer (1トークンずつ返す)
    # ============================================================

    # 次のトークンを返す。EOF に達したら EOF Token を返す。
    def next_token
      while @lex_pos < @bytes.length
        b = @bytes[@lex_pos]
        if b == SP || b == TAB
          @lex_pos += 1
        elsif b == NL
          tok = Token.new(TokenKind::NEWLINE, 0, "", @line)
          @line += 1
          @lex_pos += 1
          return tok
        elsif b == HASH
          @lex_pos += 1
          while @lex_pos < @bytes.length && @bytes[@lex_pos] != NL
            @lex_pos += 1
          end
        elsif digit?(b)
          return read_number
        elsif ident_start?(b)
          return read_keyword
        else
          return read_punct(b)
        end
      end
      Token.new(TokenKind::EOF, 0, "", @line)
    end

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
      while @lex_pos < @bytes.length && digit?(@bytes[@lex_pos])
        n = n * 10 + (@bytes[@lex_pos] - D0)
        @lex_pos += 1
      end
      Token.new(TokenKind::INT, n, "", @line)
    end

    def read_keyword
      start = @lex_pos
      while @lex_pos < @bytes.length && ident_cont?(@bytes[@lex_pos])
        @lex_pos += 1
      end
      len = @lex_pos - start
      kw = match_keyword(start, len)
      if kw == :nop
        raise "Lexer error: line #{@line}: Stage 0 はキーワードのみサポート (puts/true/false/nil)"
      end
      Token.new(kw, 0, "", @line)
    end

    def match_keyword(start, len)
      result = :nop
      if match_bytes(start, len, KW_PUTS_BYTES)
        result = TokenKind::KW_PUTS
      elsif match_bytes(start, len, KW_TRUE_BYTES)
        result = TokenKind::KW_TRUE
      elsif match_bytes(start, len, KW_FALSE_BYTES)
        result = TokenKind::KW_FALSE
      elsif match_bytes(start, len, KW_NIL_BYTES)
        result = TokenKind::KW_NIL
      end
      result
    end

    def match_bytes(start, len, kw)
      result = false
      if len == kw.length
        ok = true
        i = 0
        while i < len && ok
          if @bytes[start + i] != kw[i]
            ok = false
          end
          i += 1
        end
        result = ok
      end
      result
    end

    def read_punct(b)
      if b == PLUS_BYTE
        @lex_pos += 1
        Token.new(TokenKind::PLUS, 0, "", @line)
      elsif b == MINUS_BYTE
        @lex_pos += 1
        Token.new(TokenKind::MINUS, 0, "", @line)
      elsif b == STAR_BYTE
        @lex_pos += 1
        Token.new(TokenKind::STAR, 0, "", @line)
      elsif b == SLASH_BYTE
        @lex_pos += 1
        Token.new(TokenKind::SLASH, 0, "", @line)
      elsif b == PCT
        @lex_pos += 1
        Token.new(TokenKind::PERCENT, 0, "", @line)
      elsif b == LP
        @lex_pos += 1
        Token.new(TokenKind::LPAREN, 0, "", @line)
      elsif b == RP
        @lex_pos += 1
        Token.new(TokenKind::RPAREN, 0, "", @line)
      elsif b == EQ
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::EQ_EQ, 0, "", @line)
        else
          raise "Lexer error: line #{@line}: '=' alone is not valid in Stage 0"
        end
      elsif b == LT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::LE, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::LT, 0, "", @line)
        end
      elsif b == GT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::GE, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::GT, 0, "", @line)
        end
      else
        raise "Lexer error: line #{@line}: unexpected byte #{b}"
      end
    end

    # ============================================================
    # Parser (LL(1) pull-style)
    # ============================================================

    def at_end?
      @cur_token.kind == TokenKind::EOF
    end

    def skip_newlines
      while @cur_token.kind == TokenKind::NEWLINE
        @cur_token = next_token
      end
      nil
    end

    def consume_terminator
      k = @cur_token.kind
      if k == TokenKind::NEWLINE || k == TokenKind::EOF
        # OK; NEWLINE は次の skip_newlines で消費される
      else
        raise "Parse error: line #{@cur_token.line}: 文の終端 (改行 or EOF) が必要です"
      end
      nil
    end

    def expect(kind)
      if @cur_token.kind == kind
        @cur_token = next_token
      else
        raise "Parse error: line #{@cur_token.line}: 期待されたトークンが見つかりません"
      end
      nil
    end

    def parse_statement
      if @cur_token.kind == TokenKind::KW_PUTS
        @cur_token = next_token
        expr = parse_expression
        ASTNode.new(:puts_stmt, 0, false, :nop, nil, nil, expr)
      else
        raise "Parse error: line #{@cur_token.line}: Stage 0 では文は 'puts <expr>' のみ可"
      end
    end

    def parse_expression
      parse_comparison
    end

    def parse_comparison
      left = parse_additive
      tk = @cur_token.kind
      op = :nop
      if tk == TokenKind::EQ_EQ
        op = :eq
      elsif tk == TokenKind::LT
        op = :lt
      elsif tk == TokenKind::GT
        op = :gt
      elsif tk == TokenKind::LE
        op = :le
      elsif tk == TokenKind::GE
        op = :ge
      end
      if op != :nop
        @cur_token = next_token
        right = parse_additive
        # 連鎖チェック (もう一度判定)
        tk2 = @cur_token.kind
        if tk2 == TokenKind::EQ_EQ || tk2 == TokenKind::LT || tk2 == TokenKind::GT ||
           tk2 == TokenKind::LE   || tk2 == TokenKind::GE
          raise "Parse error: line #{@cur_token.line}: 比較演算子の連鎖は許可されていません"
        end
        ASTNode.new(:bin_op, 0, false, op, left, right, nil)
      else
        left
      end
    end

    def parse_additive
      node = parse_multiplicative
      loop do
        k = @cur_token.kind
        if k == TokenKind::PLUS
          @cur_token = next_token
          rhs = parse_multiplicative
          node = ASTNode.new(:bin_op, 0, false, :add, node, rhs, nil)
        elsif k == TokenKind::MINUS
          @cur_token = next_token
          rhs = parse_multiplicative
          node = ASTNode.new(:bin_op, 0, false, :sub, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    def parse_multiplicative
      node = parse_unary
      loop do
        k = @cur_token.kind
        if k == TokenKind::STAR
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :mul, node, rhs, nil)
        elsif k == TokenKind::SLASH
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :div, node, rhs, nil)
        elsif k == TokenKind::PERCENT
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :mod, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    def parse_unary
      if @cur_token.kind == TokenKind::MINUS
        @cur_token = next_token
        ASTNode.new(:unary_minus, 0, false, :nop, nil, nil, parse_unary)
      else
        parse_primary
      end
    end

    def parse_primary
      k = @cur_token.kind
      if k == TokenKind::INT
        v = @cur_token.int_value
        @cur_token = next_token
        ASTNode.new(:int_lit, v, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_TRUE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, true, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_FALSE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_NIL
        @cur_token = next_token
        ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::LPAREN
        @cur_token = next_token
        expr = parse_expression
        expect(TokenKind::RPAREN)
        expr
      else
        raise "Parse error: line #{@cur_token.line}: 式が必要です"
      end
    end

    # comparison_op は parse_comparison にインライン化済み (spinel の param 型推論
    # 問題回避のため)。

    # ============================================================
    # Compiler
    # ============================================================

    def compile_statement(stmt)
      if stmt.node_kind == :puts_stmt
        compile_expr(stmt.node_operand)
        @bytecode.push(Op::PUTS)
      else
        raise "Compiler bug: unknown statement kind #{stmt.node_kind}"
      end
      nil
    end

    def compile_expr(node)
      k = node.node_kind
      if k == :int_lit
        @bytecode.push(Op::PUSH_INT)
        encode_signed(node.node_int_value)
      elsif k == :bool_lit
        if node.node_bool_value
          @bytecode.push(Op::PUSH_TRUE)
        else
          @bytecode.push(Op::PUSH_FALSE)
        end
      elsif k == :nil_lit
        @bytecode.push(Op::PUSH_NIL)
      elsif k == :bin_op
        compile_expr(node.node_left)
        compile_expr(node.node_right)
        @bytecode.push(binop_to_opcode(node.node_op))
      elsif k == :unary_minus
        @bytecode.push(Op::PUSH_INT)
        encode_signed(0)
        compile_expr(node.node_operand)
        @bytecode.push(Op::SUB)
      else
        raise "Compiler bug: unknown expression kind #{k}"
      end
      nil
    end

    def binop_to_opcode(op)
      result = 0
      if op == :add
        result = Op::ADD
      elsif op == :sub
        result = Op::SUB
      elsif op == :mul
        result = Op::MUL
      elsif op == :div
        result = Op::DIV
      elsif op == :mod
        result = Op::MOD
      elsif op == :eq
        result = Op::EQ
      elsif op == :lt
        result = Op::LT
      elsif op == :gt
        result = Op::GT
      elsif op == :le
        result = Op::LE
      elsif op == :ge
        result = Op::GE
      else
        raise "Compiler bug: unknown binop #{op}"
      end
      result
    end

    def encode_signed(n)
      more = true
      while more
        byte = n & 0x7f
        n = n >> 7
        if (n == 0 && (byte & 0x40) == 0) || (n == -1 && (byte & 0x40) != 0)
          more = false
        else
          byte = byte | 0x80
        end
        @bytecode.push(byte)
      end
      nil
    end

    # ============================================================
    # VM
    # ============================================================

    def run_vm
      @pc = 0
      while true
        op = @bytecode[@pc]
        @pc += 1

        if op == Op::PUSH_INT
          n = decode_signed
          @stack.push(box_int(n))
        elsif op == Op::PUSH_TRUE
          @stack.push(ObjectVal::TRUE_VAL)
        elsif op == Op::PUSH_FALSE
          @stack.push(ObjectVal::FALSE_VAL)
        elsif op == Op::PUSH_NIL
          @stack.push(ObjectVal::NIL_VAL)
        elsif op == Op::ADD
          exec_arith(:add)
        elsif op == Op::SUB
          exec_arith(:sub)
        elsif op == Op::MUL
          exec_arith(:mul)
        elsif op == Op::DIV
          exec_arith(:div)
        elsif op == Op::MOD
          exec_arith(:mod)
        elsif op == Op::EQ
          exec_eq
        elsif op == Op::LT
          exec_compare(:lt)
        elsif op == Op::GT
          exec_compare(:gt)
        elsif op == Op::LE
          exec_compare(:le)
        elsif op == Op::GE
          exec_compare(:ge)
        elsif op == Op::PUTS
          v = @stack.pop
          puts to_puts_string(v)
        elsif op == Op::HALT
          return nil
        else
          raise "VM error: unknown opcode #{op}"
        end
      end
      nil
    end

    def fixnum?(v)
      (v & 1) == 1
    end

    def box_int(n)
      (n << 1) | 1
    end

    def unbox_int(v)
      v >> 1
    end

    def box_bool(b)
      if b
        ObjectVal::TRUE_VAL
      else
        ObjectVal::FALSE_VAL
      end
    end

    def to_puts_string(v)
      if fixnum?(v)
        unbox_int(v).to_s
      elsif v == ObjectVal::TRUE_VAL
        "true"
      elsif v == ObjectVal::FALSE_VAL
        "false"
      elsif v == ObjectVal::NIL_VAL
        ""
      else
        "#<obj>"
      end
    end

    def decode_signed
      result = 0
      shift = 0
      done = false
      while !done
        b = @bytecode[@pc]
        @pc += 1
        result = result | ((b & 0x7f) << shift)
        shift += 7
        if (b & 0x80) == 0
          if (b & 0x40) != 0
            result = result | (-1 << shift)
          end
          done = true
        end
      end
      result
    end

    def exec_arith(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: arithmetic requires Integer operands"
      end
      a = unbox_int(lhs)
      b = unbox_int(rhs)
      result = 0
      if op == :add
        result = a + b
      elsif op == :sub
        result = a - b
      elsif op == :mul
        result = a * b
      elsif op == :div
        if b == 0
          raise "ZeroDivisionError: divided by 0"
        end
        result = a / b
      elsif op == :mod
        if b == 0
          raise "ZeroDivisionError: divided by 0"
        end
        result = a % b
      else
        raise "VM bug: unknown arith #{op}"
      end
      @stack.push(box_int(result))
      nil
    end

    def exec_eq
      rhs = @stack.pop
      lhs = @stack.pop
      @stack.push(box_bool(lhs == rhs))
      nil
    end

    def exec_compare(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: comparison requires Integer operands"
      end
      a = unbox_int(lhs)
      b = unbox_int(rhs)
      r = false
      if op == :lt
        r = a < b
      elsif op == :gt
        r = a > b
      elsif op == :le
        r = a <= b
      elsif op == :ge
        r = a >= b
      else
        raise "VM bug: unknown compare #{op}"
      end
      @stack.push(box_bool(r))
      nil
    end
  end
end
