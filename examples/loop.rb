# Stage 4b: loop do ... end と break / next のデモ。

# 1) loop + break で「特定条件まで繰り返す」
i = 0
loop do
  i = i + 1
  if i >= 5
    break
  end
end
puts i

# 2) while + next で「条件に合わない要素をスキップ」
s = 0
i = 0
while i < 10
  i = i + 1
  if i % 2 == 0
    next
  end
  s = s + i
end
puts s   # 1+3+5+7+9 = 25

# 3) ネスト: 内側 loop の break は外 while に影響しない
total = 0
outer_i = 0
while outer_i < 3
  j = 0
  loop do
    j = j + 1
    if j > 4
      break
    end
    total = total + 1
  end
  outer_i = outer_i + 1
end
puts total   # 3 * 4 = 12

# 4) メソッド内で loop + break + return
def first_div_by(n, d)
  i = n
  loop do
    if i % d == 0
      return i
    end
    i = i + 1
  end
end
puts first_div_by(11, 7)   # 14

# 5) loop で配列構築 (Stage 3b の Array << と組み合わせ)
arr = []
i = 0
loop do
  if i >= 5
    break
  end
  arr << i * i
  i = i + 1
end
puts arr.length   # 5
puts arr[4]       # 16
