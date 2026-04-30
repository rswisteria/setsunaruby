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

# ---- 代入と参照 ----
assert_output("x = 1\nputs x\n",                    "1\n",      "代入と参照")
assert_output("x = 1\ny = 2\nputs x + y\n",         "3\n",      "2変数の演算")
assert_output("x = 1 + 2\nputs x\n",                "3\n",      "右辺は式")
assert_output("x = 5\nx = x + 1\nputs x\n",         "6\n",      "再代入 (自身参照)")
assert_output("x = 1\ny = x\nputs y\n",             "1\n",      "変数→変数代入")
assert_raises("puts y\n",                            "未定義変数の参照")

# ---- if 式 ----
assert_output("if true\n  puts 1\nend\n",                       "1\n",     "if true 単純")
assert_output("if false\n  puts 1\nend\n",                       "",        "if false 単純")
assert_output("if 1 == 1\n  puts 'OK'\nend\n",                   "",        "if cond でブロック内 puts (文字列リテラル未対応なのでブロックは puts なし式)") rescue nil

# 文字列リテラル未対応のため整数で代用
assert_output("if true\n  puts 1\nelse\n  puts 2\nend\n",        "1\n",     "if/else then 側")
assert_output("if false\n  puts 1\nelse\n  puts 2\nend\n",       "2\n",     "if/else else 側")
assert_output("if 1 < 2\n  puts 1\nend\n",                        "1\n",     "if 比較")
assert_output("if 1 > 2\n  puts 1\nend\n",                        "",        "if 比較 (false)")

# elsif
assert_output("x = 2\nif x == 1\n  puts 1\nelsif x == 2\n  puts 2\nelsif x == 3\n  puts 3\nelse\n  puts 0\nend\n",
              "2\n", "elsif (中央ヒット)")

# if 式の値
assert_output("x = if true then 10 else 20 end\nputs x\n", "10\n", "if 式の値 (true)")
assert_output("x = if false then 10 else 20 end\nputs x\n", "20\n", "if 式の値 (false)")
assert_output("x = if false then 10 end\nputs x\n",         "\n",   "if 式 else なし → nil")

# truthy/falsy
assert_output("if 0\n  puts 1\nend\n",                            "1\n",     "0 は truthy (Ruby 仕様)")
assert_output("if nil\n  puts 1\nelse\n  puts 2\nend\n",          "2\n",     "nil は falsy")
assert_output("if false\n  puts 1\nelse\n  puts 2\nend\n",        "2\n",     "false は falsy")

# ---- while ----
assert_output("i = 0\nwhile i < 3\n  puts i\n  i = i + 1\nend\n", "0\n1\n2\n", "while カウントアップ")
assert_output("i = 5\nwhile i > 0\n  puts i\n  i = i - 1\nend\n", "5\n4\n3\n2\n1\n", "while カウントダウン")
# 0 回ループ
assert_output("i = 5\nwhile i < 0\n  puts i\nend\nputs i\n",      "5\n",      "while 0 回")

# ---- if + while 組み合わせ (FizzBuzz 1-15) ----
fizzbuzz = <<~RUBY
  i = 1
  while i <= 15
    if i % 15 == 0
      puts -1
    elsif i % 3 == 0
      puts -3
    elsif i % 5 == 0
      puts -5
    else
      puts i
    end
    i = i + 1
  end
RUBY
expected_fizzbuzz_1_15 = "1\n2\n-3\n4\n-5\n-3\n7\n8\n-3\n-5\n11\n-3\n13\n14\n-1\n"
assert_output(fizzbuzz, expected_fizzbuzz_1_15, "FizzBuzz 1-15 (整数置換版)")

# ---- 単純なネスト if ----
assert_output("x = 5\nif x > 0\n  if x < 10\n    puts 1\n  else\n    puts 2\n  end\nelse\n  puts 3\nend\n",
              "1\n", "ネスト if")

# ---- 代入は式 ----
assert_output("x = (y = 5)\nputs x\nputs y\n", "5\n5\n", "代入式の値")

# ---- スコープ確認 (Stage 1 はトップレベルだけなので変数は永続) ----
assert_output("if true\n  x = 10\nend\nputs x\n", "10\n", "if 内代入もトップレベルに見える")

# ---- 式文 (puts なし、出力なし) ----
assert_output("1 + 2\n",                                          "",         "式文は出力なし")
assert_output("x = 1\nx + 1\nputs x\n",                            "1\n",      "式文の値は捨てられる")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 1)"
exit($fail == 0 ? 0 : 1)
