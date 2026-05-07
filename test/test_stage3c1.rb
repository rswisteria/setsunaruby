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

# ---- Integer#times: 基本 ----
assert_output("3.times do |i|\n  puts i\nend\n",  "0\n1\n2\n",         "times: 0..2 を出力")
assert_output("0.times do |i|\n  puts i\nend\n",  "",                   "times: 0 回 (出力なし)")
assert_output("1.times do |i|\n  puts i\nend\n",  "0\n",               "times: 1 回")
# param 省略
assert_output("3.times do\n  puts \"hi\"\nend\n", "hi\nhi\nhi\n",       "times: param 省略")

# ---- Integer#times: 戻り値 ----
assert_output("x = 5.times do |i|\nend\nputs x\n", "5\n",              "times: 戻り値は self")

# ---- Integer#times: ループ内で外部変数を更新 (closure read) ----
sum_via_times = <<~RUBY
  s = 0
  5.times do |i|
    s = s + i
  end
  puts s
RUBY
assert_output(sum_via_times, "10\n", "times: 外部変数を更新 (0+1+2+3+4=10)")

# ---- Integer#times: ネスト ----
nested_times = <<~RUBY
  c = 0
  3.times do |i|
    2.times do |j|
      c = c + 1
    end
  end
  puts c
RUBY
assert_output(nested_times, "6\n", "times: ネスト (3*2=6)")

# ---- Array#each: 基本 ----
assert_output("[10, 20, 30].each do |x|\n  puts x\nend\n", "10\n20\n30\n", "each: リテラル")
assert_output("[].each do |x|\n  puts x\nend\n",          "",              "each: 空配列")
assert_output("a = [1, 2, 3]\na.each do |x|\n  puts x\nend\n", "1\n2\n3\n", "each: 変数経由")

# ---- Array#each: 戻り値は self ----
back = <<~RUBY
  a = [1, 2, 3]
  b = a.each do |x|
  end
  puts b.length
RUBY
assert_output(back, "3\n", "each: 戻り値は self (length=3)")

# ---- Array#each: 集計 ----
sum_each = <<~RUBY
  s = 0
  [1, 2, 3, 4, 5].each do |x|
    s = s + x
  end
  puts s
RUBY
assert_output(sum_each, "15\n", "each: 集計")

# ---- Array#each: 条件付き処理 ----
filter_each = <<~RUBY
  a = [1, 2, 3, 4, 5]
  c = 0
  a.each do |x|
    if x > 2
      c = c + 1
    end
  end
  puts c
RUBY
assert_output(filter_each, "3\n", "each: 条件付き")

# ---- Array#each: 配列の append (3b の << と組み合わせ) ----
build_via_each = <<~RUBY
  out = []
  [1, 2, 3].each do |x|
    out << x * x
  end
  puts out
RUBY
assert_output(build_via_each, "1\n4\n9\n", "each + <<: 平方数")

# ---- ネスト each ----
nested_each = <<~RUBY
  total = 0
  [[1, 2], [3, 4]].each do |row|
    row.each do |v|
      total = total + v
    end
  end
  puts total
RUBY
assert_output(nested_each, "10\n", "each: ネスト")

# ---- 文字列要素の each ----
str_each = <<~RUBY
  ["a", "b", "c"].each do |s|
    puts s + "!"
  end
RUBY
assert_output(str_each, "a!\nb!\nc!\n", "each: 文字列要素")

# ---- メソッド内で each ----
in_method = <<~RUBY
  def sum(arr)
    s = 0
    arr.each do |x|
      s = s + x
    end
    s
  end
  puts sum([1, 2, 3, 4])
RUBY
assert_output(in_method, "10\n", "メソッド内 each")

# ---- メソッド内で times ----
in_method_times = <<~RUBY
  def factorial(n)
    r = 1
    n.times do |i|
      r = r * (i + 1)
    end
    r
  end
  puts factorial(5)
RUBY
assert_output(in_method_times, "120\n", "メソッド内 times (factorial)")

# ---- ブロックパラメータと外部変数の同名衝突 ----
# Stage 3c.1 は flat scope なので、|i| はブロック後も残る (Ruby 1.9+ とは divergence)。
# Stage 3d.5 で each/times/map が class table 経由になり、block prologue が yield 値を
# slot に書く形に変わったため、終了時 i は最後に yield された値 (= n-1 = 2)。
shadow = <<~RUBY
  i = 99
  3.times do |i|
  end
  puts i
RUBY
assert_output(shadow, "2\n", "param と外部変数同名 (Stage 3c.1: flat scope、終了時 i=n-1)")

# ---- エラー系 ----
assert_raises("3.times do |i, j|\nend\n",                      "多パラメータブロックは未対応")
assert_raises("3.foo do |x|\nend\n",                            "未対応 method はエラー")
assert_raises("[1, 2].push do |x|\nend\n",                     "push にブロックは未対応")
# .each / .times はそれぞれ受信者が必要 — 文字列 each はエラー (Stage 3c.1 スコープ外)
assert_raises("\"abc\".each do |c|\nend\n",                    "String#each は未対応")
# n.times の n が String → ループ条件 (LT) で型エラー
assert_raises("\"abc\".times do |i|\nend\n",                   "String#times は未対応")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3c.1)"
exit($fail == 0 ? 0 : 1)
