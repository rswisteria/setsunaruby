# Stage 3d.1: 最小クラス機能のショーケース。

class Counter
  def reset
    @n = 0
  end
  def value
    @n
  end
  def inc
    @n = @n + 1
  end
end

c = Counter.new
c.reset
c.inc
c.inc
c.inc
puts c.value

# 複数インスタンスは独立
d = Counter.new
d.reset
d.inc
puts d.value
puts c.value

# self 経由のメソッド呼び出し + @var 演算
class Rect
  def init(w, h)
    @w = w
    @h = h
  end
  def area
    @w * @h
  end
  def double_area
    self.area * 2
  end
end

r = Rect.new
r.init(3, 4)
puts r.area
puts r.double_area

# クラス method 内で each + yield (Stage 3c.1/3c.2 連動)
class Sum
  def of(arr)
    s = 0
    arr.each do |x|
      s = s + x
    end
    s
  end
  def filter(arr)
    out = []
    arr.each do |x|
      if yield x
        out << x
      end
    end
    out
  end
end

s = Sum.new
puts s.of([1, 2, 3, 4, 5])

evens = s.filter([1, 2, 3, 4, 5, 6]) do |x|
  x % 2 == 0
end
puts evens
