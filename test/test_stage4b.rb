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

# ---- loop + break ----
loop_break = <<~RUBY
  i = 0
  loop do
    i = i + 1
    if i >= 5
      break
    end
  end
  puts i
RUBY
assert_output(loop_break, "5\n", "loop + break で終了")

# loop の値は nil (while と同じ)
assert_output("x = loop do\n  break\nend\nputs x\n", "\n", "loop 全体の値は nil")

# break が無いと暴走するので、テストは必ず break する形のみ
counter = <<~RUBY
  n = 0
  loop do
    n = n + 1
    if n == 100
      break
    end
  end
  puts n
RUBY
assert_output(counter, "100\n", "loop で 100 回まで")

# ---- while + break ----
while_break = <<~RUBY
  i = 0
  while true
    i = i + 1
    if i >= 3
      break
    end
  end
  puts i
RUBY
assert_output(while_break, "3\n", "while true + break")

while_break2 = <<~RUBY
  i = 0
  while i < 100
    i = i + 1
    if i == 7
      break
    end
  end
  puts i
RUBY
assert_output(while_break2, "7\n", "while + break で早抜け")

# ---- next ----
next_basic = <<~RUBY
  s = 0
  i = 0
  while i < 10
    i = i + 1
    if i % 2 == 0
      next
    end
    s = s + i
  end
  puts s
RUBY
assert_output(next_basic, "25\n", "next で偶数を skip → 1+3+5+7+9 = 25")

next_in_loop = <<~RUBY
  s = 0
  i = 0
  loop do
    i = i + 1
    if i > 5
      break
    end
    if i == 3
      next
    end
    s = s + i
  end
  puts s
RUBY
assert_output(next_in_loop, "12\n", "loop 中で next + break (3 を skip、1+2+4+5)")

# ---- ネスト ----
nested_break = <<~RUBY
  outer = 0
  inner = 0
  i = 0
  while i < 3
    j = 0
    loop do
      j = j + 1
      if j >= 2
        break
      end
      inner = inner + 1
    end
    outer = outer + 1
    i = i + 1
  end
  puts outer
  puts inner
RUBY
assert_output(nested_break, "3\n3\n", "ネスト: 内側 loop の break は外 while を抜けない")

nested_next = <<~RUBY
  s = 0
  i = 0
  while i < 3
    i = i + 1
    j = 0
    while j < 5
      j = j + 1
      if j == 2
        next
      end
      s = s + 1
    end
  end
  puts s
RUBY
assert_output(nested_next, "12\n", "ネスト: 内側の next は外 while に影響しない (3 * 4 = 12)")

# 同じ深度で break と next の混在
mix = <<~RUBY
  s = 0
  i = 0
  loop do
    i = i + 1
    if i > 10
      break
    end
    if i % 3 == 0
      next
    end
    s = s + i
  end
  puts s
RUBY
# 1+2+4+5+7+8+10 = 37
assert_output(mix, "37\n", "loop 中で break + next 混在")

# ---- メソッド内 ----
in_method = <<~RUBY
  def find_first_even(start)
    i = start
    loop do
      if i % 2 == 0
        return i
      end
      i = i + 1
    end
  end
  puts find_first_even(7)
RUBY
assert_output(in_method, "8\n", "メソッド内 loop と return")

in_method_break = <<~RUBY
  def sum_until(limit)
    s = 0
    i = 0
    loop do
      i = i + 1
      if i > limit
        break
      end
      s = s + i
    end
    s
  end
  puts sum_until(10)
RUBY
assert_output(in_method_break, "55\n", "メソッド内 loop + break で値を返す")

# ---- エラー系 ----
assert_raises("break\n", "break は loop / while の外でエラー")
assert_raises("next\n", "next は loop / while の外でエラー")
assert_raises("def f\n  break\nend\nf\n", "メソッド内でも loop の外なら break エラー")
assert_raises("def f\n  next\nend\nf\n", "メソッド内でも loop の外なら next エラー")

# ブロック内 break は Stage 4b ではサポート外
assert_raises("[1,2,3].each do |x|\n  if x == 2\n    break\n  end\n  puts x\nend\n",
              "ブロックから外側 loop への break は不可 (#40 スコープ外)")

# loop do 構文以外は parse error
assert_raises("loop\n  break\nend\n", "loop の後に do が必要")

# 単独 'loop'
assert_raises("loop", "loop だけはエラー")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4b)"
exit($fail == 0 ? 0 : 1)
