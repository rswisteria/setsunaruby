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

# ---- Array#length は引き続き動作 (builtin として) ----
assert_output("puts [1, 2, 3].length\n",            "3\n",   "Array#length: builtin で動作")
assert_output("puts [].length\n",                   "0\n",   "Array#length: 空配列")
assert_output("a = [10, 20, 30, 40]\nputs a.length\n", "4\n",  "Array#length: 変数経由")

# ---- ユーザクラスに length method を定義可能 (Stage 3d.2 では衝突していた) ----
user_length = <<~RUBY
  class Stack
    def initialize
      @items = []
    end
    def push(x)
      @items << x
    end
    def length
      @items.length
    end
  end
  s = Stack.new
  s.push("a")
  s.push("b")
  s.push("c")
  puts s.length
RUBY
assert_output(user_length, "3\n", "Stack#length と Array#length が共存")

# ---- 同名メソッドの class_idx 区別 ----
two_lens = <<~RUBY
  class Counter
    def initialize
      @n = 0
    end
    def inc
      @n = @n + 1
    end
    def length
      @n * 100
    end
  end
  c = Counter.new
  c.inc
  c.inc
  c.inc
  puts c.length
  puts [1, 2].length
RUBY
assert_output(two_lens, "300\n2\n", "ユーザ length と builtin length は class_idx で区別")

# ---- Integer に length は未定義 → NoMethodError ----
assert_raises("puts 1.length\n", "Integer#length は builtin にも未定義 (Stage 3d.3)")

# ---- String にも未定義 (Stage 3d.4 以降で追加予定) ----
assert_raises('puts "abc".length' + "\n", "String#length は Stage 3d.3 ではまだ未対応")

# ---- ユーザクラスのインスタンスは class_idx を heap_instance_class から取る ----
user_chain = <<~RUBY
  class Box
    def initialize(v)
      @v = v
    end
    def length
      999
    end
  end
  puts Box.new(0).length
  puts [10, 20, 30, 40, 50].length
RUBY
assert_output(user_chain, "999\n5\n", "user instance と builtin Array が独立に dispatch")

# ---- length 以外の dot method は引き続き special form (each / times / map) ----
assert_output("3.times do |i|\n  puts i\nend\n",            "0\n1\n2\n",   "Integer#times は引き続き special form")
assert_output("[1, 2, 3].each do |x|\n  puts x\nend\n",     "1\n2\n3\n",   "Array#each は引き続き special form")
assert_output("puts [1, 2, 3].map do |x|\n  x * 10\nend\n", "10\n20\n30\n", "Array#map は引き続き special form")

# ---- ユーザ class が times/each/map を定義しても special form が優先される (Stage 3d.3 制約) ----
# 制約の確認: `each` という名前のユーザ method は special form が割り込み、
# compile_each_block が ARRAY_LEN を emit するので receiver が user instance だと runtime error。
shadowed = <<~RUBY
  class Strange
    def each
      yield 1
    end
  end
  Strange.new.each do |x|
    puts x
  end
RUBY
assert_raises(shadowed, "ユーザ class の each は special form に intercept されて runtime error (Stage 3d.4 で解決予定)")

# ---- ただし each 以外の名前 (例: iter) ならユーザ method が CALL_METHOD_WITH_BLOCK で動く ----
user_block_method = <<~RUBY
  class Strange
    def iter
      yield 1
      yield 2
    end
  end
  Strange.new.iter do |x|
    puts x
  end
RUBY
assert_output(user_block_method, "1\n2\n", "non-special 名のユーザ block 取り method は動く")

# ---- length method を持たない user class は NoMethodError ----
no_length = <<~RUBY
  class NoLen
    def x
      42
    end
  end
  NoLen.new.length
RUBY
assert_raises(no_length, "method 未定義の user class で length 呼び出しは NoMethodError")

# ---- builtin Array#length は内部で LOAD_SELF + ARRAY_LEN + RETURN を使う ----
# 動作確認: 配列の長さが正しく取れる
assert_output("puts [\"a\", \"b\", \"c\", \"d\", \"e\"].length\n", "5\n", "Array#length 経由で 5")

# ---- 大量呼び出しで Array#length builtin の RETURN/LOAD_SELF/ARRAY_LEN がループしない ----
large_loop = <<~RUBY
  c = 0
  100.times do |i|
    c = c + [1, 2, 3, 4, 5].length
  end
  puts c
RUBY
assert_output(large_loop, "500\n", "100 回ループで Array#length を呼び出す (5 * 100 = 500)")

# ---- ユーザ method が builtin を内部で使う ----
inner_use = <<~RUBY
  class Wrapper
    def initialize(arr)
      @arr = arr
    end
    def doubled_length
      @arr.length * 2
    end
  end
  w = Wrapper.new([1, 2, 3])
  puts w.doubled_length
RUBY
assert_output(inner_use, "6\n", "user method が内部で arr.length を呼ぶ")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3d.3)"
exit($fail == 0 ? 0 : 1)
