module Setsunaruby
  # 単一の ASTNode 型で全ての式・文を表現する。kind シンボルで種別を区別。
  # 各フィールドは「使うとき」だけ意味を持つ。未使用フィールドはデフォルト値。
  #
  # kind の取りうる値:
  #   :int_lit      → int_value
  #   :bool_lit     → bool_value
  #   :nil_lit      → (なし)
  #   :bin_op       → op (Symbol), left (ASTNode), right (ASTNode)
  #   :unary_minus  → operand (ASTNode)
  #   :puts_stmt    → operand (ASTNode)
  #
  # Note: spinel の `def self.xxx` 型推論バグ回避のため factory method は持たない。
  # 構築は呼び出し元でインライン化する。
  class ASTNode
    attr_accessor :kind
    attr_accessor :int_value
    attr_accessor :bool_value
    attr_accessor :op
    attr_accessor :left
    attr_accessor :right
    attr_accessor :operand

    def initialize(kind)
      @kind       = kind
      @int_value  = 0
      @bool_value = false
      @op         = :nop
      @left       = nil
      @right      = nil
      @operand    = nil
    end
  end
end
