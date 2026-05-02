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

# ---- 引数なし yield ----
basic_no_arg = <<~RUBY
  def hi
    yield
    yield
  end
  hi do
    puts 1
  end
RUBY
assert_output(basic_no_arg, "1\n1\n", "引数なし yield 2 回")

# ---- 1 引数 yield ----
basic_with_arg = <<~RUBY
  def emit(x)
    yield x
  end
  emit(42) do |v|
    puts v
  end
RUBY
assert_output(basic_with_arg, "42\n", "yield arg 単純")

# ---- yield をループから呼ぶ (each の自前実装) ----
my_each = <<~RUBY
  def my_each(arr)
    i = 0
    while i < arr.length
      yield arr[i]
      i = i + 1
    end
  end
  my_each([10, 20, 30]) do |x|
    puts x
  end
RUBY
assert_output(my_each, "10\n20\n30\n", "ユーザ定義 each (yield in while)")

# ---- closure: 外部変数を block 内で更新 ----
closure = <<~RUBY
  def my_each(arr)
    i = 0
    while i < arr.length
      yield arr[i]
      i = i + 1
    end
  end
  s = 0
  my_each([1, 2, 3, 4, 5]) do |v|
    s = s + v
  end
  puts s
RUBY
assert_output(closure, "15\n", "closure: block が caller 変数を更新")

# ---- yield の戻り値を method 内で使う ----
yield_return = <<~RUBY
  def transform(arr)
    out = []
    i = 0
    while i < arr.length
      out << yield arr[i]
      i = i + 1
    end
    out
  end
  r = transform([1, 2, 3]) do |x|
    x * x
  end
  puts r
RUBY
assert_output(yield_return, "1\n4\n9\n", "yield 戻り値で map 自前実装")

# ---- yield なしの method ----
no_yield = <<~RUBY
  def quiet
    42
  end
  puts quiet
RUBY
assert_output(no_yield, "42\n", "yield なしのメソッドは従来通り")

# ---- block を渡さずに yield → エラー ----
assert_raises(<<~RUBY, "block なしで yield → LocalJumpError")
  def needs_block
    yield 1
  end
  needs_block
RUBY

# ---- yield argc / block param 数の不一致は Ruby と同様 lenient (Stage 3d.5) ----
# 余剰引数は捨て、不足分は nil で埋める。エラーにならない。
assert_output(<<~RUBY, "no param\n", "yield 1 + ブロック param 0 → 引数を捨てる")
  def emit
    yield 42
  end
  emit do
    puts "no param"
  end
RUBY
assert_output(<<~RUBY, "\n", "yield 0 + ブロック param 1 → param は nil")
  def emit
    yield
  end
  emit do |x|
    puts x
  end
RUBY

# ---- ネスト yield ----
nested_yield = <<~RUBY
  def repeat(n)
    i = 0
    while i < n
      yield
      i = i + 1
    end
  end
  c = 0
  repeat(3) do
    repeat(2) do
      c = c + 1
    end
  end
  puts c
RUBY
assert_output(nested_yield, "6\n", "ネスト yield (3 * 2 = 6)")

# ---- yield 戻り値を変数代入 ----
yield_assign = <<~RUBY
  def gen
    yield
  end
  x = gen do
    99
  end
  puts x
RUBY
assert_output(yield_assign, "99\n", "yield 戻り値を変数代入")

# ---- if 内で yield ----
yield_in_if = <<~RUBY
  def maybe(b)
    if b
      yield
    end
  end
  maybe(true) do
    puts "yes"
  end
  maybe(false) do
    puts "no"
  end
RUBY
assert_output(yield_in_if, "yes\n", "if 内 yield (true 側のみ実行)")

# ---- block 内で別 method 呼び出し ----
call_in_block = <<~RUBY
  def double(x)
    x * 2
  end
  def emit(v)
    yield v
  end
  emit(5) do |x|
    puts double(x)
  end
RUBY
assert_output(call_in_block, "10\n", "block 内から別 method 呼び出し")

# ---- yield と Stage 3c.1 の each 共存 ----
mixed = <<~RUBY
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
assert_output(mixed, "101\n102\n103\n", "Stage 3c.1 each + 3c.2 yield 共存 (map 自前実装)")

# ---- block from inside method (caller scope is method's locals) ----
caller_scope_method = <<~RUBY
  def my_iter(n)
    i = 0
    while i < n
      yield i
      i = i + 1
    end
  end
  def run
    s = 0
    my_iter(5) do |i|
      s = s + i
    end
    s
  end
  puts run
RUBY
assert_output(caller_scope_method, "10\n", "block scope = caller (run の s)、my_iter の i は別")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3c.2)"
exit($fail == 0 ? 0 : 1)
