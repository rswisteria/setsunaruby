# Stage 3c.1: Array#each と Integer#times のショーケース。

# Integer#times: 0 から n-1 までブロックを呼ぶ
3.times do |i|
  puts i
end

# Array#each: 各要素にブロックを呼ぶ
[10, 20, 30].each do |x|
  puts x
end

# 集計: 外部変数を更新 (closure 的振る舞い)
sum = 0
[1, 2, 3, 4, 5].each do |v|
  sum = sum + v
end
puts sum

# ネスト + 配列構築
squares = []
5.times do |i|
  squares << (i + 1) * (i + 1)
end
puts squares

# メソッド + ブロック
def total(arr)
  s = 0
  arr.each do |x|
    s = s + x
  end
  s
end
puts total([10, 20, 30, 40])
