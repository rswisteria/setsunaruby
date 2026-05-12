# JIT ベンチ: 2 引数 Fixnum 加算のタイトループ。
# add メソッドが JIT 化される (FIXNUM_ADD → ADD + SUB_IMM #1)。
# 期待: AOT/JIT 比は小〜中。bytecode の場合は CALL のスタックフレーム push + ADD opcode
# dispatch が支配的、JIT の場合は MOV X0/X1 + ADD + SUB_IMM + MOV RAX + RET の機械語直行。
def add(a, b)
  a + b
end

i = 0
sum = 0
while i < 1000000
  sum = add(sum, 1)
  i = i + 1
end
puts sum
