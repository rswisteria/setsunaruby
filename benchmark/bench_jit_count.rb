# JIT ベンチ: while ループを内部に持つ method を呼ぶ。
# count_up 自体に multi-BB + phi がある。1 回の呼び出しで 1000 回の iter を回し、
# それを 2000 回繰り返すので内部ループ計 200 万 iter。最初の 100 呼び出しは
# bytecode、それ以降が JIT 経由。
# 期待: JIT は inner loop の cmp + b.cond + add #imm を機械語直行で回せる。
def count_up(n)
  i = 0
  while i < n
    i = i + 1
  end
  i
end

k = 0
r = 0
while k < 2000
  r = count_up(1000)
  k = k + 1
end
puts r
