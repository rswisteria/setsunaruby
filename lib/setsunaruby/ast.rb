# spinel が ASTNode と Token のフィールドを共通化して同一視しないよう、
# ASTNode のフィールド名には node_ プレフィックスを付ける。
class ASTNode
  attr_accessor :node_kind, :node_int_value, :node_bool_value,
                :node_op, :node_left, :node_right, :node_operand

  def initialize(kind, int_value, bool_value, op, left, right, operand)
    @node_kind       = kind
    @node_int_value  = int_value
    @node_bool_value = bool_value
    @node_op         = op
    @node_left       = left
    @node_right      = right
    @node_operand    = operand
  end
end
