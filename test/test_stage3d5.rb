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

def assert_raises_with(src, fragment, label)
  err = nil
  begin
    run_source(src)
  rescue StandardError => e
    err = e
  end
  if err && err.message.include?(fragment)
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  expected fragment: #{fragment.inspect}"
    puts "  actual:            #{err && err.message.inspect}"
  end
end

# ==========================================
# A. each / times / map class table 化
# ==========================================

# ユーザ定義 each も builtin と同じく一般 dispatch される (Stage 3d.3 では intercept されていた)
user_each = <<~RUBY
  class Stack
    def initialize
      @items = []
    end
    def push(x)
      @items << x
    end
    def each
      yield @items[0]
      yield @items[1]
    end
  end
  s = Stack.new
  s.push(10)
  s.push(20)
  s.each do |x|
    puts x
  end
RUBY
assert_output(user_each, "10\n20\n", "ユーザ class の each も dispatch される")

# yield arity と block param 数の不一致は Ruby 互換に lenient
yield_lenient_extra = <<~RUBY
  def emit
    yield 42
  end
  emit do
    puts "no param"
  end
RUBY
assert_output(yield_lenient_extra, "no param\n", "yield 1 + block 0: 余剰 arg は捨てる")

yield_lenient_short = <<~RUBY
  def emit
    yield
  end
  emit do |x|
    puts x
  end
RUBY
assert_output(yield_lenient_short, "\n", "yield 0 + block 1: 不足 arg は nil")

# ネストした block-内 yield (collect が arr.each を内部で使う典型)
collect_pattern = <<~RUBY
  def collect(arr)
    out = []
    arr.each do |x|
      out << yield(x)
    end
    out
  end
  r = collect([1, 2, 3]) do |x|
    x + 100
  end
  puts r
RUBY
assert_output(collect_pattern, "101\n102\n103\n", "block 内 yield: arr.each 経由で外側 method の block を呼ぶ")

# block_given? も lexical method の block を見る
block_given_lexical = <<~RUBY
  def maybe_iter(arr)
    if block_given?
      arr.each do |x|
        yield x
      end
    else
      puts "no block"
    end
  end
  maybe_iter([1, 2])
  maybe_iter([1, 2]) do |x|
    puts x
  end
RUBY
assert_output(block_given_lexical, "no block\n1\n2\n", "block_given? も lexical method の block を見る")

# Integer#times も class table 経由
times_basic = <<~RUBY
  3.times do |i|
    puts i
  end
RUBY
assert_output(times_basic, "0\n1\n2\n", "Integer#times: builtin dispatch")

# Array#map も class table 経由
map_basic = <<~RUBY
  r = [1, 2, 3].map do |x|
    x * 10
  end
  puts r
RUBY
assert_output(map_basic, "10\n20\n30\n", "Array#map: builtin dispatch")

# ==========================================
# B. super
# ==========================================

# 引数なしの bare super (現メソッドの args をそのまま転送)
super_bare = <<~RUBY
  class A
    def f(x)
      x + 1
    end
  end
  class B < A
    def f(x)
      super + 100
    end
  end
  puts B.new.f(5)
RUBY
assert_output(super_bare, "106\n", "bare super で現メソッドの args を転送")

# 明示的 super(args)
super_explicit = <<~RUBY
  class A
    def f(x, y)
      x + y
    end
  end
  class B < A
    def f(x, y)
      super(x * 2, y * 3) + 100
    end
  end
  puts B.new.f(1, 2)
RUBY
assert_output(super_explicit, "108\n", "super(args) で明示引数")

# 明示的 super() で 0 引数
super_explicit_empty = <<~RUBY
  class A
    def f(x)
      x * 10
    end
    def g
      99
    end
  end
  class B < A
    def g
      super() + 1
    end
  end
  puts B.new.g
RUBY
assert_output(super_explicit_empty, "100\n", "super() で 0 引数明示")

# super で initialize 連鎖
super_initialize = <<~RUBY
  class Base
    def initialize(name)
      @name = name
    end
    def name
      @name
    end
  end
  class Child < Base
    def initialize(name, age)
      super(name)
      @age = age
    end
    def info
      @name + ":" + @age.to_s
    end
  end
  c = Child.new("Alice", 30)
  puts c.info
RUBY
# to_s が未実装 → Integer.to_s が CRuby 標準で動く環境のみ。spinel だと?
# Stage 3d.5 では Integer#to_s が builtin にない可能性あり。スキップ判断保留。
# 確実に動く別形に変更:
super_initialize2 = <<~RUBY
  class Base
    def initialize(name)
      @name = name
    end
  end
  class Child < Base
    def initialize(name, suffix)
      super(name)
      @suffix = suffix
    end
    def shout
      @name + " " + @suffix
    end
  end
  c = Child.new("Alice", "Hello!")
  puts c.shout
RUBY
assert_output(super_initialize2, "Alice Hello!\n", "super で initialize 連鎖")

# 多段継承 (Grandchild → Child → Base)
super_chain = <<~RUBY
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
RUBY
assert_output(super_chain, "ABC\n", "多段継承 chain で super が祖先まで遡る")

# super を skip (中間クラスが override しなければ親に直接行く)
super_skip = <<~RUBY
  class A
    def greet
      "A"
    end
  end
  class B < A
  end
  class C < B
    def greet
      super + "C"
    end
  end
  puts C.new.greet
RUBY
assert_output(super_skip, "AC\n", "中間クラス未override なら祖先まで直接")

# super 不在の親 (= NoMethodError)
super_no_parent = <<~RUBY
  class A
    def f
      super
    end
  end
  A.new.f
RUBY
assert_raises_with(super_no_parent, "親クラスがありません", "親なし class での super はエラー")

# 親 chain に method が無い場合 (= NoMethodError)
super_method_missing = <<~RUBY
  class A
    def existing
      "ok"
    end
  end
  class B < A
    def f
      super
    end
  end
  B.new.f
RUBY
assert_raises_with(super_method_missing, "該当 method", "親 chain に同名 method なしはエラー")

# arity mismatch
super_arity = <<~RUBY
  class A
    def f(x, y)
      x + y
    end
  end
  class B < A
    def f(x)
      super(x)
    end
  end
  B.new.f(1)
RUBY
assert_raises_with(super_arity, "arity", "super: arity mismatch")

# top-level での super はパースは通るが compile error
super_toplevel = <<~RUBY
  super
RUBY
assert_raises_with(super_toplevel, "method 内", "top-level での super は compile error")

puts ""
puts "#{$pass} passed, #{$fail} failed"
exit($fail == 0 ? 0 : 1)
