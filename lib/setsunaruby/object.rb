module Setsunaruby
  # 即値オブジェクトの定数のみを定義する module。
  # タグ付け操作 (fixnum?/box_int/unbox_int/box_bool/to_puts_string) は
  # spinel の poly 推論問題回避のため VM の private method として実装する。
  module ObjectVal
    NIL_VAL   = 0
    FALSE_VAL = 2
    TRUE_VAL  = 4
  end
end
