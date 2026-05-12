# JIT ベンチ: 恒等関数 (= dispatch + return のみ) の最小ベースライン。
# AOT (no-JIT) と AOT (JIT) の差は JIT.callN 経由のディスパッチ削減のみが効く。
# 期待: AOT/JIT 比は小さめ (ホットメソッドの中身が軽すぎる)。
def id(n)
  n
end

i = 0
r = 0
while i < 5000000
  r = id(i)
  i = i + 1
end
puts r
