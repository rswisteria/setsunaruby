# Stage 3b: 配列リテラル / index / `<<` / `.length` / puts。
puts [1, 2, 3].length

a = []
i = 0
while i < 5
  a << (i + 1) * 10
  i = i + 1
end
puts a.length
puts a[0]
puts a[4]

a[2] = 999
puts a

b = [a[0], a[1], a[2]]
puts b.length

# ネスト配列
nested = [[1, 2], [3, 4, 5]]
puts nested.length
puts nested[1].length
puts nested[1][2]

# 異種要素
mixed = [1, "two", true, nil, [9]]
puts mixed
