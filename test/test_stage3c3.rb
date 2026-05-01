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

# ---- Lexer: 識別子末尾の ? ----
# block_given? の前提として識別子に ? を許す。`?` 単独はエラー。
assert_output(<<~RUBY, "false\n", "block_given?: ブロックなしで false")
  def f
    puts block_given?
  end
  f
RUBY
assert_output(<<~RUBY, "true\n", "block_given?: ブロックありで true")
  def f
    puts block_given?
  end
  f do
  end
RUBY

# ---- block_given? の典型用法 ----
optional_block = <<~RUBY
  def emit
    if block_given?
      yield 7
    else
      puts "no block"
    end
  end
  emit
  emit do |v|
    puts v
  end
RUBY
assert_output(optional_block, "no block\n7\n", "block_given? で yield 分岐")

# ---- block_given? は引数を取らない ----
assert_raises("block_given?(1)\n", "block_given? に引数 → エラー")
# ブロック付きで block_given? を呼ぶのもエラー
assert_raises(<<~RUBY, "block_given? にブロック → エラー")
  block_given? do
  end
RUBY

# ---- Array#map: 基本 ----
assert_output("a = [1, 2, 3].map do |x|\n  x * 2\nend\nputs a\n", "2\n4\n6\n", "map: 倍化")
assert_output("puts [1, 2, 3].map do |x|\n  x + 100\nend\n",      "101\n102\n103\n", "map: 直接 puts")
assert_output("puts [].map do |x|\n  x\nend\n",                     "",        "map: 空配列")
# map の戻り値は新しい配列、元は不変
assert_output(<<~RUBY, "1\n2\n3\nyes\n", "map: 元配列は不変")
  a = [1, 2, 3]
  b = a.map do |x|
    x + 10
  end
  puts a
  if a.length == 3
    puts "yes"
  else
    puts "no"
  end
RUBY

# ---- Array#map: ネスト ----
nested_map = <<~RUBY
  matrix = [[1, 2], [3, 4]]
  flat = matrix.map do |row|
    row.length
  end
  puts flat
RUBY
assert_output(nested_map, "2\n2\n", "map: ネスト配列の length")

# ---- 中括弧ブロック { } ----
brace_basic = <<~RUBY
  3.times { |i|
    puts i
  }
RUBY
assert_output(brace_basic, "0\n1\n2\n", "中括弧: times")

# 1 行
assert_output("3.times { |i| puts i }\n", "0\n1\n2\n", "中括弧: 1 行 times")

# each / map でも使える
assert_output("[10, 20].each { |x| puts x }\n",          "10\n20\n",          "中括弧: each")
assert_output("puts [1, 2, 3].map { |x| x * x }\n",      "1\n4\n9\n",         "中括弧: map")

# ユーザ定義 method + 中括弧
user_brace = <<~RUBY
  def emit(x)
    yield x
  end
  emit(99) { |v|
    puts v
  }
RUBY
assert_output(user_brace, "99\n", "中括弧: ユーザ定義 yield")

# 中括弧の closure
brace_closure = <<~RUBY
  s = 0
  5.times { |i|
    s = s + i
  }
  puts s
RUBY
assert_output(brace_closure, "10\n", "中括弧: closure read/write")

# ---- map と yield の混在 ----
mixed = <<~RUBY
  def transform(arr)
    arr.map { |x|
      yield x
    }
  end
  r = transform([1, 2, 3]) do |x|
    x * 10
  end
  puts r
RUBY
assert_output(mixed, "10\n20\n30\n", "method 内の map + 外側の yield")

# ---- ! 識別子も lex できる ----
# (現状 ! を持つ method はないが、構文として lex 通ること)
assert_raises("foo!\n", "foo! は未定義 method として lex は通るが compile error")

# ---- キーワード + ? / ! は IDENT 扱い (lexer bug 回帰防止) ----
# `true?` / `nil?` / `false?` 等は KW_TRUE 等を返さず識別子として lex されるべき。
# 未定義 method として compile error になるが、lexer は正しく通すこと。
assert_raises("puts true?\n",   "true? は IDENT (未定義 method) として compile error")
assert_raises("puts nil?\n",    "nil? は IDENT (未定義 method) として compile error")
assert_raises("puts false?\n",  "false? は IDENT (未定義 method) として compile error")
assert_raises("foo!\n",         "foo! も同上")

# ---- 中括弧と do の同等 ----
brace_eq_do = <<~RUBY
  a = [1, 2, 3].map do |x| x + 1 end
  b = [1, 2, 3].map { |x| x + 1 }
  if a.length == b.length
    puts "ok"
  else
    puts "ng"
  end
  puts a
  puts b
RUBY
assert_output(brace_eq_do, "ok\n2\n3\n4\n2\n3\n4\n", "中括弧と do は同等")

# ---- block_given? のネスト ----
nested_block_given = <<~RUBY
  def inner
    puts block_given?
  end
  def outer
    puts block_given?
    inner
    inner do
    end
  end
  outer do
  end
RUBY
assert_output(nested_block_given, "true\nfalse\ntrue\n", "block_given? は最内 method の状態")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3c.3)"
exit($fail == 0 ? 0 : 1)
