# Stage 3d.2: initialize と引数付き .new

class Point
  def initialize(x, y)
    @x = x
    @y = y
  end
  def distance_from_origin
    @x * @x + @y * @y
  end
  def to_a
    [@x, @y]
  end
end

p = Point.new(3, 4)
puts p.distance_from_origin
puts p.to_a

# 階乗を保持するクラス
class Factorial
  def initialize(n)
    @n = n
    @result = 1
    i = 1
    while i <= n
      @result = @result * i
      i = i + 1
    end
  end
  def value
    @result
  end
end

5.times do |i|
  puts Factorial.new(i + 1).value
end

# Stack クラスを実装
class Stack
  def initialize
    @items = []
  end
  def push(x)
    @items << x
  end
  def all
    @items
  end
  def size
    # Stage 3d.2 では `length` は Array 専用 special form のため別名 size を使う。
    # Stage 3d.3 で一般 method dispatch に乗せ替え予定。
    @items.length
  end
end

s = Stack.new
s.push("a")
s.push("b")
s.push("c")
puts s.size
puts s.all
