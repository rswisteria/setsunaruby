$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/interp'
require 'stringio'

$pass = 0
$fail = 0

def run_source(src)
  buf   = StringIO.new
  saved = $stdout
  $stdout = buf
  begin
    Setsunaruby::Interp.new.run_string(src)
  ensure
    $stdout = saved
  end
  buf.string
end

def assert_output(src, expected, label)
  actual = run_source(src)
  if actual == expected
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  expected: #{expected.inspect}"
    puts "  actual:   #{actual.inspect}"
  end
end

def assert_raises(src, label)
  ok = false
  begin
    run_source(src)
  rescue StandardError
    ok = true
  end
  if ok
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label} (expected to raise)"
  end
end

# ---- 親 method の継承 ----
inherit_method = <<~RUBY
  class Animal
    def speak
      "..."
    end
  end
  class Dog < Animal
  end
  puts Dog.new.speak
RUBY
assert_output(inherit_method, "...\n", "親 method を子から呼べる")

# ---- override (子が同名 method を再定義) ----
override = <<~RUBY
  class Animal
    def speak
      "..."
    end
  end
  class Dog < Animal
    def speak
      "Woof"
    end
  end
  class Cat < Animal
    def speak
      "Meow"
    end
  end
  puts Animal.new.speak
  puts Dog.new.speak
  puts Cat.new.speak
RUBY
assert_output(override, "...\nWoof\nMeow\n", "子で override")

# ---- 親の @var を子から read/write ----
inherit_ivar = <<~RUBY
  class Counter
    def initialize
      @n = 0
    end
    def inc
      @n = @n + 1
    end
    def value
      @n
    end
  end
  class StepCounter < Counter
    def step(s)
      @n = @n + s
    end
  end
  c = StepCounter.new
  c.inc
  c.step(10)
  c.step(5)
  puts c.value
RUBY
assert_output(inherit_ivar, "16\n", "子から親の @var を read/write")

# ---- 子で新しい @var を追加 ----
new_ivar = <<~RUBY
  class A
    def initialize
      @x = 1
    end
    def x
      @x
    end
  end
  class B < A
    def init_y
      @y = 99
    end
    def y
      @y
    end
  end
  b = B.new
  b.init_y
  puts b.x
  puts b.y
RUBY
assert_output(new_ivar, "1\n99\n", "子で新しい @var を追加 (親の @x と独立 slot)")

# ---- 親と子で同名 @var (slot 共有) ----
shared_ivar = <<~RUBY
  class A
    def initialize
      @v = 1
    end
    def get_a
      @v
    end
  end
  class B < A
    def set_b(x)
      @v = x
    end
  end
  b = B.new
  puts b.get_a
  b.set_b(42)
  puts b.get_a
RUBY
assert_output(shared_ivar, "1\n42\n", "親と子で同名 @v は同じ slot")

# ---- 子の initialize 継承 ----
inherit_init = <<~RUBY
  class Point
    def initialize(x, y)
      @x = x
      @y = y
    end
    def to_s_pair
      @x + @y
    end
  end
  class ColoredPoint < Point
  end
  p = ColoredPoint.new(3, 4)
  puts p.to_s_pair
RUBY
assert_output(inherit_init, "7\n", "子は親の initialize を継承")

# ---- 子で initialize 上書き ----
override_init = <<~RUBY
  class A
    def initialize(x)
      @x = x
    end
    def x
      @x
    end
  end
  class B < A
    def initialize
      @x = 99
    end
  end
  puts A.new(7).x
  puts B.new.x
RUBY
assert_output(override_init, "7\n99\n", "子で initialize 上書き (親の arity と異なって OK)")

# ---- 親の method が子の override を呼ぶ (動的ディスパッチ) ----
dynamic_dispatch = <<~RUBY
  class Base
    def hello
      self.greeting + "!"
    end
    def greeting
      "Hi"
    end
  end
  class Cheerful < Base
    def greeting
      "Hello"
    end
  end
  puts Base.new.hello
  puts Cheerful.new.hello
RUBY
assert_output(dynamic_dispatch, "Hi!\nHello!\n", "親 method 内 self.method() は子の override に dispatch")

# ---- 多段継承 ----
multi_level = <<~RUBY
  class A
    def kind
      "A"
    end
  end
  class B < A
  end
  class C < B
  end
  puts A.new.kind
  puts B.new.kind
  puts C.new.kind
RUBY
assert_output(multi_level, "A\nA\nA\n", "多段継承 (C → B → A): C.kind は A まで遡って解決")

# ---- ネストレベル + 上書き ----
multi_override = <<~RUBY
  class A
    def f
      1
    end
  end
  class B < A
    def f
      2
    end
  end
  class C < B
  end
  puts A.new.f
  puts B.new.f
  puts C.new.f
RUBY
assert_output(multi_override, "1\n2\n2\n", "C.f は B.f を継承 (A まで遡らない)")

# ---- block 取り method の継承 ----
inherit_block = <<~RUBY
  class A
    def emit_two
      yield 1
      yield 2
    end
  end
  class B < A
  end
  B.new.emit_two do |x|
    puts x
  end
RUBY
assert_output(inherit_block, "1\n2\n", "親の block 取り method を子から呼べる")

# ---- 親未定義エラー ----
assert_raises("class B < Undef\n  def x\n  end\nend\n", "未定義の親クラス → コンパイルエラー")

# ---- builtin を親にすることは禁止 ----
assert_raises("class A < Array\n  def x\n    @x\n  end\nend\n", "builtin Array を親にするのは禁止 (Stage 3d.4 スコープ外)")

# ---- 親の length method を子で継承 ----
override_length = <<~RUBY
  class Base
    def length
      99
    end
  end
  class Sub < Base
  end
  puts Base.new.length
  puts Sub.new.length
  puts [1, 2, 3].length
RUBY
assert_output(override_length, "99\n99\n3\n", "user class の length 継承 + Array#length は独立")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3d.4)"
exit($fail == 0 ? 0 : 1)
