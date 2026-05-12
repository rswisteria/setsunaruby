# Stage 4c: Symbol literal の例。
# `:foo` は内部的に Integer ID (intern table の idx) として扱われ、
# `==` `!=` で obj_id 比較として動作する。`puts :foo` は "foo" を出力する。

puts :hello

# 同名は同 id、異名は別 id
puts :tag == :tag
puts :tag == :other

# 異型は常に false
puts :foo == "foo"
puts :foo == 1

# kind tag 風の分岐 (interp.rb 内部で多用するパターンの動作確認)
def show(kind)
  if kind == :int_lit
    puts "integer literal"
  elsif kind == :bin_op
    puts "binary op"
  elsif kind == :var_ref
    puts "variable reference"
  else
    puts "unknown"
  end
end

show(:int_lit)
show(:bin_op)
show(:var_ref)
show(:str_lit)

# predicate symbol (`?` 末尾) と destructive symbol (`!` 末尾) も別 symbol 扱い
puts :ready?
puts :flush!
puts :ready? == :ready
