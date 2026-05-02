# Stage 3d.5: super と各 builtin (each / map / times) のショーケース。

# 1. super で initialize 連鎖
class Base
  def initialize(name)
    @name = name
  end
  def label
    @name
  end
end

class Tagged < Base
  def initialize(name, tag)
    super(name)
    @tag = tag
  end
  def label
    "[" + @tag + "] " + super
  end
end

puts Base.new("Alice").label
puts Tagged.new("Bob", "VIP").label

# 2. 多段継承で super チェーン
class A
  def greet
    "A"
  end
end

class B < A
  def greet
    super + "B"
  end
end

class C < B
  def greet
    super + "C"
  end
end

puts C.new.greet

# 3. ユーザ class の each (Stage 3d.5 で intercept されなくなった)
class Range2
  def initialize(lo, hi)
    @lo = lo
    @hi = hi
  end
  def each
    i = @lo
    while i < @hi
      yield i
      i = i + 1
    end
  end
end

Range2.new(3, 7).each do |n|
  puts n
end

# 4. arr.each + 外側 method の block (yield from inside a yielded block)
def collect(arr)
  out = []
  arr.each do |x|
    out << yield(x)
  end
  out
end

doubled = collect([1, 2, 3]) do |x|
  x * 2
end
puts doubled

# 5. Integer#times と Array#map の組み合わせ
total = 0
3.times do |i|
  total = total + i
end
puts total

squares = [1, 2, 3, 4].map do |n|
  n * n
end
puts squares
