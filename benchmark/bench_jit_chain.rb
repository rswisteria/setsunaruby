# JIT ベンチ: 多変数 + 多算術の method を hot loop で 50 万回呼ぶ。
# ローカル変数を 4 つ使うので allocator pool (5 reg) をほぼ全部使う。
# 期待: AOT/JIT 比は中。bytecode の per-opcode dispatch コストが多いほど JIT 有利。
def calc(a, b, c)
  d = a + b
  e = d + c
  f = e + a
  g = f + b
  g
end

i = 0
r = 0
while i < 500000
  r = calc(i, 2, 3)
  i = i + 1
end
puts r
