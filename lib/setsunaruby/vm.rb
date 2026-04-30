require_relative 'opcodes'
require_relative 'object'
require_relative 'leb128'

module Setsunaruby
  class VM
    def initialize(bytecode)
      @code  = bytecode
      @stack = []
      @pc    = 0
      @leb   = Leb128.new
      @om    = ObjectModel.new
    end

    def run
      while true
        op = @code[@pc]
        @pc += 1

        if op == Op::PUSH_INT
          pair = @leb.decode_signed(@code, @pc)
          n     = pair[0]
          @pc   = pair[1]
          @stack.push(@om.box_int(n))
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
          puts @om.to_puts_string(v)
        elsif op == Op::HALT
          return
        else
          raise "VM error: unknown opcode #{op}"
        end
      end
    end

    private

    def exec_arith(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !@om.fixnum?(lhs) || !@om.fixnum?(rhs)
        raise "TypeError: arithmetic requires Integer operands"
      end
      a = @om.unbox_int(lhs)
      b = @om.unbox_int(rhs)
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
      @stack.push(@om.box_int(result))
    end

    def exec_eq
      rhs = @stack.pop
      lhs = @stack.pop
      @stack.push(@om.box_bool(lhs == rhs))
    end

    def exec_compare(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !@om.fixnum?(lhs) || !@om.fixnum?(rhs)
        raise "TypeError: comparison requires Integer operands"
      end
      a = @om.unbox_int(lhs)
      b = @om.unbox_int(rhs)
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
      @stack.push(@om.box_bool(r))
    end
  end
end
