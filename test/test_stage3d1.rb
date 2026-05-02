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

# ---- 最小クラス ----
basic = <<~RUBY
  class Foo
    def hi
      42
    end
  end
  puts Foo.new.hi
RUBY
assert_output(basic, "42\n", "クラス + 引数なし method + .new")

# ---- 引数あり method ----
with_args = <<~RUBY
  class Adder
    def add(a, b)
      a + b
    end
  end
  obj = Adder.new
  puts obj.add(3, 4)
RUBY
assert_output(with_args, "7\n", "引数 2 つの method")

# ---- インスタンス変数 ----
ivar = <<~RUBY
  class Counter
    def set(n)
      @n = n
    end
    def value
      @n
    end
    def inc
      @n = @n + 1
    end
  end
  c = Counter.new
  c.set(10)
  puts c.value
  c.inc
  c.inc
  puts c.value
RUBY
assert_output(ivar, "10\n12\n", "インスタンス変数 @n の read/write")

# ---- 複数インスタンスの独立性 ----
two = <<~RUBY
  class Box
    def put(x)
      @v = x
    end
    def get
      @v
    end
  end
  a = Box.new
  b = Box.new
  a.put(1)
  b.put(99)
  puts a.get
  puts b.get
RUBY
assert_output(two, "1\n99\n", "2 つのインスタンスで @var が独立")

# ---- self キーワード ----
self_test = <<~RUBY
  class Echo
    def me
      self
    end
    def same(other)
      if self == other
        puts "eq"
      else
        puts "neq"
      end
    end
  end
  a = Echo.new
  b = Echo.new
  x = a.me
  a.same(x)
  a.same(b)
RUBY
assert_output(self_test, "eq\nneq\n", "self は受信者を返す + == は obj_id 比較")

# ---- self 経由の method 呼び出し ----
self_dispatch = <<~RUBY
  class Greeter
    def hello
      "hi"
    end
    def call_hello
      self.hello
    end
  end
  puts Greeter.new.call_hello
RUBY
assert_output(self_dispatch, "hi\n", "self.method 呼び出し")

# ---- インスタンス変数同士の演算 ----
arith_ivar = <<~RUBY
  class Rect
    def init(w, h)
      @w = w
      @h = h
    end
    def area
      @w * @h
    end
  end
  r = Rect.new
  r.init(3, 4)
  puts r.area
RUBY
assert_output(arith_ivar, "12\n", "@var 同士の演算")

# ---- @var 配列 ----
ivar_arr = <<~RUBY
  class Stack
    def init
      @items = []
    end
    def push(x)
      @items << x
    end
    def all
      @items
    end
  end
  s = Stack.new
  s.init
  s.push(1)
  s.push(2)
  s.push(3)
  puts s.all
RUBY
assert_output(ivar_arr, "1\n2\n3\n", "@var が配列で push が反映")

# ---- インスタンス変数の初期値は nil ----
nil_init = <<~RUBY
  class Box
    def get
      @v
    end
  end
  puts Box.new.get
RUBY
assert_output(nil_init, "\n", "未代入の @var は nil (puts は空行)")

# ---- メソッドが他のメソッドを呼ぶ (self 経由) ----
chain = <<~RUBY
  class Chain
    def a
      self.b + 1
    end
    def b
      10
    end
  end
  puts Chain.new.a
RUBY
assert_output(chain, "11\n", "メソッド間呼び出し (self 経由)")

# ---- if 内で @var を使う ----
ivar_if = <<~RUBY
  class Cond
    def set(b)
      @flag = b
    end
    def show
      if @flag
        puts "yes"
      else
        puts "no"
      end
    end
  end
  c = Cond.new
  c.set(true)
  c.show
  c.set(false)
  c.show
RUBY
assert_output(ivar_if, "yes\nno\n", "@var を if 条件に")

# ---- 同名 method を異なるクラスに ----
two_classes = <<~RUBY
  class A
    def kind
      "A"
    end
  end
  class B
    def kind
      "B"
    end
  end
  puts A.new.kind
  puts B.new.kind
RUBY
assert_output(two_classes, "A\nB\n", "別クラスの同名 method は独立")

# ---- 既存 Array#each / map / times がクラス機能と共存 ----
coexist = <<~RUBY
  class Sum
    def of(arr)
      s = 0
      arr.each do |x|
        s = s + x
      end
      s
    end
  end
  puts Sum.new.of([1, 2, 3, 4, 5])
RUBY
assert_output(coexist, "15\n", "method 内で each ブロック")

# ---- Stage 3c.2 の yield と共存 ----
yield_in_class = <<~RUBY
  class Iter
    def run
      yield 1
      yield 2
    end
  end
  Iter.new.run do |x|
    puts x
  end
RUBY
assert_output(yield_in_class, "1\n2\n", "クラス method 内で yield")

# ---- エラー系 ----
assert_raises(<<~RUBY, "未定義クラスの .new はエラー (一般 method dispatch にフォールバックして NoMethodError)")
  Undef.new
RUBY
assert_raises(<<~RUBY, "未定義 method 呼び出し")
  class Foo
    def hi
      99
    end
  end
  Foo.new.bye
RUBY
assert_raises(<<~RUBY, "ネストクラスは禁止")
  class A
    class B
      def x
      end
    end
  end
RUBY
assert_raises(<<~RUBY, "クラス内に def 以外は禁止")
  class A
    x = 1
  end
RUBY
assert_raises("@x = 1\n", "トップレベルでの @var はエラー")
assert_raises(<<~RUBY, "method 内 def の中で @var は OK だが、トップレベル method で @var は不可 (= compile error)")
  def f
    @x = 1
  end
  f
RUBY
assert_raises(<<~RUBY, "引数 mismatch")
  class C
    def add(a, b)
      a + b
    end
  end
  C.new.add(1)
RUBY
# 同名クラス再定義
assert_raises(<<~RUBY, "同名クラスは再定義禁止")
  class C
    def x
    end
  end
  class C
    def y
    end
  end
RUBY

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3d.1)"
exit($fail == 0 ? 0 : 1)
