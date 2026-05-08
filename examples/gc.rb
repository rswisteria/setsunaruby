# Stage GC-1: STW Mark-Sweep のデモ。
# 大量に短命 String / Array を alloc しても heap slot は頭打ちで完走することを示す。
# GC 無し時代は @heap_kind.length が 10000 を超えて膨らんでいたが、GC-1 では
# free list 再利用により 1024 程度に頭打ちになる。

i = 0
while i < 5000
  s = "x" + "y"          # 毎反復で新 String slot を alloc、前反復の s は unreachable
  a = [s, s, s]          # 毎反復で新 Array slot
  i = i + 1
end
puts "done: " + s
puts a[0]
puts a[2]
