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

# ---- 引数なし initialize ----
no_args = <<~RUBY
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
  c = Counter.new
  c.inc
  c.inc
  puts c.value
RUBY
assert_output(no_args, "2\n", "引数なし initialize で @var 初期化")

# ---- 1 引数 initialize ----
one_arg = <<~RUBY
  class Box
    def initialize(v)
      @v = v
    end
    def get
      @v
    end
  end
  puts Box.new(42).get
  puts Box.new("hi").get
RUBY
assert_output(one_arg, "42\nhi\n", "1 引数 initialize")

# ---- 多引数 initialize ----
multi_args = <<~RUBY
  class Rect
    def initialize(w, h)
      @w = w
      @h = h
    end
    def area
      @w * @h
    end
  end
  puts Rect.new(3, 4).area
  puts Rect.new(7, 8).area
RUBY
assert_output(multi_args, "12\n56\n", "2 引数 initialize")

# ---- initialize 内で他 method を呼べる ----
init_call_method = <<~RUBY
  class Greeter
    def initialize(name)
      @name = name
      self.greet
    end
    def greet
      puts "Hello, " + @name
    end
  end
  Greeter.new("world")
RUBY
assert_output(init_call_method, "Hello, world\n", "initialize 内で self.method() 呼び出し")

# ---- initialize の戻り値は無視され .new はインスタンスを返す ----
ignore_return = <<~RUBY
  class Foo
    def initialize
      @x = 10
      999
    end
    def x
      @x
    end
  end
  f = Foo.new
  puts f.x
RUBY
assert_output(ignore_return, "10\n", ".new は initialize の戻り値ではなくインスタンスを返す")

# ---- initialize 内のローカル変数 ----
init_locals = <<~RUBY
  class Sum
    def initialize(a, b)
      tmp = a * 2
      @result = tmp + b
    end
    def result
      @result
    end
  end
  puts Sum.new(3, 4).result
RUBY
assert_output(init_locals, "10\n", "initialize 内ローカル変数")

# ---- initialize なしのクラス (3d.1 互換) ----
no_init = <<~RUBY
  class Empty
    def hello
      "hi"
    end
  end
  puts Empty.new.hello
RUBY
assert_output(no_init, "hi\n", "initialize 未定義 (3d.1 互換)")

# ---- 引数なし .new で class が initialize を持つ ----
mismatch_no_args = <<~RUBY
  class Need
    def initialize(x)
      @x = x
    end
    def x
      @x
    end
  end
RUBY
assert_raises(mismatch_no_args + "Need.new\n", "initialize あり + 引数なし .new はエラー")
assert_raises(mismatch_no_args + "Need.new(1, 2)\n", "initialize 1 引数 + .new 2 引数はエラー")

# ---- initialize なしのクラスに .new で引数 ----
init_none_args = <<~RUBY
  class Plain
    def x
      1
    end
  end
  Plain.new(99)
RUBY
assert_raises(init_none_args, "initialize 未定義 + 引数付き .new はエラー")

# ---- initialize に block を渡そうとするとエラー ----
init_block = <<~RUBY
  class B
    def initialize
    end
  end
  B.new do
  end
RUBY
assert_raises(init_block, ".new に block を渡すとエラー")

# ---- 複数インスタンスで initialize が独立に走る ----
multiple_init = <<~RUBY
  class C
    def initialize(x)
      @x = x
    end
    def x
      @x
    end
  end
  a = C.new(1)
  b = C.new(2)
  puts a.x
  puts b.x
  puts a.x
RUBY
assert_output(multiple_init, "1\n2\n1\n", "複数インスタンスで initialize が独立")

# ---- initialize と他 method の同時 (3c 連携) ----
init_with_each = <<~RUBY
  class List
    def initialize
      @items = []
    end
    def add(x)
      @items << x
    end
    def all
      @items
    end
    def total
      s = 0
      @items.each do |v|
        s = s + v
      end
      s
    end
  end
  l = List.new
  l.add(10)
  l.add(20)
  l.add(30)
  puts l.total
  puts l.all
RUBY
assert_output(init_with_each, "60\n10\n20\n30\n", "initialize + @items + each")

# ---- ネストした .new (一方の initialize が他方の .new を呼ぶ) ----
nested_new = <<~RUBY
  class Inner
    def initialize(v)
      @v = v
    end
    def v
      @v
    end
  end
  class Outer
    def initialize(x)
      @inner = Inner.new(x * 10)
    end
    def inner_v
      @inner.v
    end
  end
  puts Outer.new(5).inner_v
RUBY
assert_output(nested_new, "50\n", "ネストした .new")

# ---- self return from initialize is irrelevant ----
self_in_init = <<~RUBY
  class S
    def initialize
      @me = self
    end
    def same?
      if @me == self
        puts "same"
      else
        puts "diff"
      end
    end
  end
  S.new.same?
RUBY
assert_output(self_in_init, "same\n", "initialize 内 self は 結果と同一インスタンス")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3d.2)"
exit($fail == 0 ? 0 : 1)
