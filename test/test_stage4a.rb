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

# ---- 整数のシフト ----
assert_output("puts 1 << 3\n",            "8\n",      "<<: 整数左シフト")
assert_output("puts 8 >> 2\n",            "2\n",      ">>: 整数右シフト")
assert_output("puts 1 << 0\n",            "1\n",      "<< 0 は恒等")
assert_output("puts 0 << 5\n",            "0\n",      "0 << n = 0")
assert_output("puts 1 << 30\n",           (1 << 30).to_s + "\n", "<< 30")

# ---- ビット AND / OR / XOR / NOT ----
assert_output("puts 12 & 10\n",           "8\n",      "&: 整数 AND")
assert_output("puts 12 | 10\n",           "14\n",     "|: 整数 OR")
assert_output("puts 12 ^ 10\n",           "6\n",      "^: 整数 XOR")
assert_output("puts ~0\n",                "-1\n",     "~: 整数 NOT (0 → -1)")
assert_output("puts ~5\n",                "-6\n",     "~: 整数 NOT (5 → -6)")
assert_output("puts ~(~7)\n",             "7\n",      "~~ は恒等")

# ---- 不等価 ----
assert_output("puts 1 != 2\n",            "true\n",   "!=: 異なる Fixnum")
assert_output("puts 1 != 1\n",            "false\n",  "!=: 同じ Fixnum")
assert_output("puts true != false\n",     "true\n",   "!=: bool")
assert_output("puts 1 != true\n",         "true\n",   "!=: 異型")
assert_output("puts nil != nil\n",        "false\n",  "!=: nil 同士")

# ---- 否定 ----
assert_output("puts !true\n",             "false\n",  "!: true → false")
assert_output("puts !false\n",            "true\n",   "!: false → true")
assert_output("puts !nil\n",              "true\n",   "!: nil は falsy")
assert_output("puts !0\n",                "false\n",  "!: 0 は truthy")
assert_output("puts !!true\n",            "true\n",   "!!: 二重否定")
assert_output("puts !1\n",                "false\n",  "!: 1 は truthy")

# ---- 短絡 && ----
assert_output("puts true && true\n",      "true\n",   "&&: true && true")
assert_output("puts true && false\n",     "false\n",  "&&: true && false")
assert_output("puts false && true\n",     "false\n",  "&&: false && true (短絡で右辺評価しない)")
assert_output("puts 1 && 2\n",            "2\n",      "&&: lhs truthy → rhs を返す")
assert_output("puts nil && 2\n",          "\n",       "&&: nil && X → nil")
assert_output("puts false && 2\n",        "false\n",  "&&: false && X → false")

# 短絡確認: 副作用を持つ右辺が評価されないこと。
short_circuit_and = <<~RUBY
  x = 0
  if false && (x = 1)
    puts "in-then"
  end
  puts x
RUBY
assert_output(short_circuit_and, "0\n", "&&: false の場合 rhs 副作用は起きない")

# ---- 短絡 || ----
assert_output("puts true || false\n",     "true\n",   "||: true || X (短絡)")
assert_output("puts false || true\n",     "true\n",   "||: false || true")
assert_output("puts nil || 7\n",          "7\n",      "||: nil → rhs を返す")
assert_output("puts false || 0\n",        "0\n",      "||: false → rhs (0 は truthy)")
assert_output("puts 5 || 6\n",            "5\n",      "||: lhs truthy → lhs を返す")

short_circuit_or = <<~RUBY
  x = 0
  if true || (x = 1)
    puts "in-then"
  end
  puts x
RUBY
assert_output(short_circuit_or, "in-then\n0\n", "||: true の場合 rhs 副作用は起きない")

# ---- 演算子優先順位 ----
assert_output("puts 1 + 2 << 1\n",        "6\n",      "+ は << より高い ((1+2)<<1)")
assert_output("puts 1 << 1 + 1\n",        "4\n",      "+ は << より高い (1<<(1+1))")
assert_output("puts 1 | 2 & 3\n",         "3\n",      "& は | より高い (1|(2&3))")
assert_output("puts 1 & 3 | 4\n",         "5\n",      "& は | より高い ((1&3)|4)")
assert_output("puts 1 << 2 | 1\n",        "5\n",      "<< は | より高い ((1<<2)|1)")
assert_output("puts 1 + 2 == 3\n",        "true\n",   "+ は == より高い")
assert_output("puts 1 == 1 && 2 == 2\n",  "true\n",   "== は && より高い")
assert_output("puts 1 == 1 || 1 == 2\n",  "true\n",   "== は || より高い")
assert_output("puts true && false || true\n", "true\n", "&& は || より高い ((T&&F)||T)")
assert_output("puts !true || false\n",    "false\n",  "! と || (!Tは||の左で先に評価)")
assert_output("puts !(false || false)\n", "true\n",   "括弧で || 全体を否定")

# ---- ~ と + の優先順位 ----
# ~5 = -6、-6 + 1 = -5
assert_output("puts ~5 + 1\n",            "-5\n",     "~ は + より高い ((~5)+1)")
# 1 + ~0 = 1 + (-1) = 0
assert_output("puts 1 + ~0\n",            "0\n",      "~ は + より高い (1+(~0))")

# ---- packed name 風の式 (interp.rb 内部で多用される形) ----
assert_output("start = 5\nlen = 3\nputs (start << 16) | len\n", "327683\n", "packed name 風")

# ---- ビット演算と if 条件の組み合わせ ----
combined = <<~RUBY
  v = 14
  if (v & 1) == 0
    puts "even"
  else
    puts "odd"
  end
RUBY
assert_output(combined, "even\n", "v & 1 == 0 で偶奇判定")

# ---- while + && (loop guard 風) ----
loop_guard = <<~RUBY
  i = 0
  s = 0
  while i < 5 && s < 100
    s = s + i
    i = i + 1
  end
  puts s
  puts i
RUBY
assert_output(loop_guard, "10\n5\n", "while 条件に && を使う")

# ---- 配列 << は依然として動く (多態性の保持) ----
array_push = <<~RUBY
  a = []
  a << 1
  a << 2
  puts a.length
RUBY
assert_output(array_push, "2\n", "Array << は Stage 3b 通り動く (多態保持)")

# ---- 文字列 << も動く (多態性の保持) ----
string_append = <<~RUBY
  s = "ab"
  s << "cd"
  puts s
RUBY
assert_output(string_append, "abcd\n", "String << String は Stage 3a 通り動く")

# ---- 型エラー ----
assert_raises("puts 1 >> 1.0\n",          ">>: 浮動小数は字句エラー")
assert_raises("puts true & 1\n",          "&: 非整数はエラー")
assert_raises("puts true | 1\n",          "|: 非整数はエラー")
assert_raises("puts true ^ false\n",      "^: 非整数はエラー")
assert_raises("puts ~true\n",             "~: 非整数はエラー")

# ---- 比較演算子の連鎖は依然エラー ----
assert_raises("puts 1 < 2 < 3\n",         "比較演算子の連鎖は禁止 (既存)")
assert_raises("puts 1 == 1 == 1\n",       "等価演算子の連鎖は禁止 (Stage 4a)")
assert_raises("puts 1 != 1 != 1\n",       "不等価演算子の連鎖は禁止 (Stage 4a)")

# ---- ループ・メソッド内でも動く ----
in_method = <<~RUBY
  def is_even(n)
    (n & 1) == 0
  end
  puts is_even(4)
  puts is_even(7)
RUBY
assert_output(in_method, "true\nfalse\n", "メソッド内でビット AND")

short_circuit_method = <<~RUBY
  def safe_div(a, b)
    if b != 0 && a >= b
      a / b
    else
      0
    end
  end
  puts safe_div(10, 3)
  puts safe_div(10, 0)
  puts safe_div(2, 5)
RUBY
assert_output(short_circuit_method, "3\n0\n0\n", "メソッド内で && 短絡 (b != 0 で 0 除算回避)")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4a)"
exit($fail == 0 ? 0 : 1)
