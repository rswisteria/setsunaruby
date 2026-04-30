module Setsunaruby
  # オブジェクト表現とタグ付け操作。
  # spinel の `def self.xxx` 型推論バグ回避のためインスタンスメソッドで提供。
  # 値定数は ObjectVal に分離 (定数なら module でも OK)。
  module ObjectVal
    NIL_VAL   = 0
    FALSE_VAL = 2
    TRUE_VAL  = 4
  end

  class ObjectModel
    def fixnum?(v)
      (v & 1) == 1
    end

    def truthy?(v)
      v != ObjectVal::NIL_VAL && v != ObjectVal::FALSE_VAL
    end

    def box_int(n)
      (n << 1) | 1
    end

    def unbox_int(v)
      v >> 1
    end

    def box_bool(b)
      b ? ObjectVal::TRUE_VAL : ObjectVal::FALSE_VAL
    end

    # Ruby の `puts` 相当。
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
  end
end
