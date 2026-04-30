require_relative 'token'
require_relative 'ast'

module Setsunaruby
  class Parser
    def initialize(tokens)
      @tokens = tokens
      @pos    = 0
    end

    # Array[ASTNode] を返す (各要素は文)。
    def parse_program
      stmts = []
      skip_newlines
      while !at_end?
        stmts.push(parse_statement)
        consume_terminator
        skip_newlines
      end
      stmts
    end

    private

    # statement := 'puts' expression
    def parse_statement
      tok = peek
      if tok.kind == TokenKind::KW && tok.str_value == 'puts'
        advance
        expr = parse_expression
        n = ASTNode.new(:puts_stmt)
        n.operand = expr
        n
      else
        raise "Parse error: line #{tok.line}: Stage 0 では文は 'puts <expr>' のみ可"
      end
    end

    def parse_expression
      parse_comparison
    end

    # comparison := additive (('==' | '<' | '>' | '<=' | '>=') additive)?
    def parse_comparison
      left = parse_additive
      tok = peek
      op = comparison_op(tok.kind)
      if op != :nop
        advance
        right = parse_additive
        nxt = peek
        if comparison_op(nxt.kind) != :nop
          raise "Parse error: line #{nxt.line}: 比較演算子の連鎖は許可されていません"
        end
        n = ASTNode.new(:bin_op)
        n.op    = op
        n.left  = left
        n.right = right
        n
      else
        left
      end
    end

    # additive := multiplicative (('+' | '-') multiplicative)*
    def parse_additive
      node = parse_multiplicative
      loop do
        tok = peek
        if tok.kind == TokenKind::PLUS
          advance
          rhs = parse_multiplicative
          new_node = ASTNode.new(:bin_op)
          new_node.op    = :add
          new_node.left  = node
          new_node.right = rhs
          node = new_node
        elsif tok.kind == TokenKind::MINUS
          advance
          rhs = parse_multiplicative
          new_node = ASTNode.new(:bin_op)
          new_node.op    = :sub
          new_node.left  = node
          new_node.right = rhs
          node = new_node
        else
          break
        end
      end
      node
    end

    # multiplicative := unary (('*' | '/' | '%') unary)*
    def parse_multiplicative
      node = parse_unary
      loop do
        tok = peek
        if tok.kind == TokenKind::STAR
          advance
          rhs = parse_unary
          new_node = ASTNode.new(:bin_op)
          new_node.op    = :mul
          new_node.left  = node
          new_node.right = rhs
          node = new_node
        elsif tok.kind == TokenKind::SLASH
          advance
          rhs = parse_unary
          new_node = ASTNode.new(:bin_op)
          new_node.op    = :div
          new_node.left  = node
          new_node.right = rhs
          node = new_node
        elsif tok.kind == TokenKind::PERCENT
          advance
          rhs = parse_unary
          new_node = ASTNode.new(:bin_op)
          new_node.op    = :mod
          new_node.left  = node
          new_node.right = rhs
          node = new_node
        else
          break
        end
      end
      node
    end

    # unary := '-' unary | primary
    def parse_unary
      tok = peek
      if tok.kind == TokenKind::MINUS
        advance
        n = ASTNode.new(:unary_minus)
        n.operand = parse_unary
        n
      else
        parse_primary
      end
    end

    # primary := INT | 'true' | 'false' | 'nil' | '(' expression ')'
    def parse_primary
      tok = peek
      if tok.kind == TokenKind::INT
        advance
        n = ASTNode.new(:int_lit)
        n.int_value = tok.int_value
        n
      elsif tok.kind == TokenKind::KW && tok.str_value == 'true'
        advance
        n = ASTNode.new(:bool_lit)
        n.bool_value = true
        n
      elsif tok.kind == TokenKind::KW && tok.str_value == 'false'
        advance
        n = ASTNode.new(:bool_lit)
        n.bool_value = false
        n
      elsif tok.kind == TokenKind::KW && tok.str_value == 'nil'
        advance
        ASTNode.new(:nil_lit)
      elsif tok.kind == TokenKind::LPAREN
        advance
        expr = parse_expression
        expect(TokenKind::RPAREN)
        expr
      else
        raise "Parse error: line #{tok.line}: 式が必要です"
      end
    end

    # ---- ヘルパ ----

    def peek
      @tokens[@pos]
    end

    def advance
      tok = @tokens[@pos]
      @pos += 1
      tok
    end

    def at_end?
      peek.kind == TokenKind::EOF
    end

    def skip_newlines
      while peek.kind == TokenKind::NEWLINE
        advance
      end
    end

    def consume_terminator
      tok = peek
      if tok.kind == TokenKind::NEWLINE || tok.kind == TokenKind::EOF
        # OK
      else
        raise "Parse error: line #{tok.line}: 文の終端 (改行 or EOF) が必要です"
      end
    end

    def expect(kind)
      tok = peek
      if tok.kind == kind
        advance
      else
        raise "Parse error: line #{tok.line}: 期待されたトークンが見つかりません"
      end
    end

    def comparison_op(kind)
      if    kind == TokenKind::EQ_EQ then :eq
      elsif kind == TokenKind::LT    then :lt
      elsif kind == TokenKind::GT    then :gt
      elsif kind == TokenKind::LE    then :le
      elsif kind == TokenKind::GE    then :ge
      else :nop
      end
    end
  end
end
