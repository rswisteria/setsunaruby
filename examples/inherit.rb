# Stage 3d.4: 継承のショーケース。

class Animal
  def initialize(name)
    @name = name
  end
  def name
    @name
  end
  def describe
    self.name + " says " + self.sound
  end
  def sound
    "..."
  end
end

class Dog < Animal
  def sound
    "Woof"
  end
end

class Cat < Animal
  def sound
    "Meow"
  end
end

class Puppy < Dog
  def sound
    "yip"
  end
end

puts Animal.new("Generic").describe
puts Dog.new("Rex").describe
puts Cat.new("Mia").describe
puts Puppy.new("Tiny").describe

# 子で @var を追加
class Counter
  def initialize
    @n = 0
  end
  def value
    @n
  end
  def inc
    @n = @n + 1
  end
end

class StepCounter < Counter
  def initialize(s)
    @n = 0
    @step = s
  end
  def step
    @n = @n + @step
  end
end

c = StepCounter.new(5)
c.inc
c.step
c.step
puts c.value
