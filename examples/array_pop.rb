# Stage 4d: Array#pop / Array#last。pop は末尾要素を返して配列長を 1 減らす。
# last は配列を変更せず末尾要素だけ返す。空配列はどちらも nil。

a = [1, 2, 3, 4]
puts a.pop      # 4
puts a.pop      # 3
puts a.length   # 2
puts a.last     # 2
puts a.last     # 2 (last は破壊しない)
puts a.pop      # 2
puts a.length   # 1
puts a.pop      # 1
puts a.length   # 0

# 空配列の pop / last は nil (puts は空行)
empty = []
puts empty.pop
puts empty.last
puts empty.length   # 0 のまま

# << と組み合わせて stack 的に使う
stk = []
stk << 10
stk << 20
stk << 30
puts stk.pop    # 30
puts stk.pop    # 20
puts stk.pop    # 10
puts stk.length # 0
