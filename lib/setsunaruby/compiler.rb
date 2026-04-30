require_relative 'ast'
require_relative 'opcodes'
require_relative 'leb128'

module Setsunaruby
  class Compiler
    def initialize
      @bytes = []
      @leb   = Leb128.new
    end

    # statements: Array[ASTNode]
    def compile(statements)
      statements.each do |stmt|
        compile_statement(stmt)
      end
      @bytes.push(Op::HALT)
      @bytes
    end

    private

    def compile_statement(stmt)
      if stmt.kind == :puts_stmt
        compile_expr(stmt.operand)
        @bytes.push(Op::PUTS)
      else
        raise "Compiler bug: unknown statement kind #{stmt.kind}"
      end
    end

    def compile_expr(node)
      k = node.kind
      if k == :int_lit
        @bytes.push(Op::PUSH_INT)
        @leb.encode_signed(node.int_value, @bytes)
      elsif k == :bool_lit
        if node.bool_value
          @bytes.push(Op::PUSH_TRUE)
        else
          @bytes.push(Op::PUSH_FALSE)
        end
      elsif k == :nil_lit
        @bytes.push(Op::PUSH_NIL)
      elsif k == :bin_op
        compile_expr(node.left)
        compile_expr(node.right)
        @bytes.push(binop_to_opcode(node.op))
      elsif k == :unary_minus
        @bytes.push(Op::PUSH_INT)
        @leb.encode_signed(0, @bytes)
        compile_expr(node.operand)
        @bytes.push(Op::SUB)
      else
        raise "Compiler bug: unknown expression kind #{k}"
      end
    end

    def binop_to_opcode(op)
      if    op == :add then Op::ADD
      elsif op == :sub then Op::SUB
      elsif op == :mul then Op::MUL
      elsif op == :div then Op::DIV
      elsif op == :mod then Op::MOD
      elsif op == :eq  then Op::EQ
      elsif op == :lt  then Op::LT
      elsif op == :gt  then Op::GT
      elsif op == :le  then Op::LE
      elsif op == :ge  then Op::GE
      else raise "Compiler bug: unknown binop #{op}"
      end
    end
  end
end
