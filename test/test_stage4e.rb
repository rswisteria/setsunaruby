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

# ---- String#bytes ----
assert_output("puts \"abc\".bytes\n",         "97\n98\n99\n", "BYTES: 通常文字列")
assert_output("puts \"\".bytes.length\n",     "0\n",          "BYTES: 空文字列は長さ 0 の Array")
assert_output("puts \"a\".bytes.length\n",    "1\n",          "BYTES: 1 文字文字列")
assert_output("b = \"abc\".bytes\nputs b[0]\nputs b[2]\n",
              "97\n99\n", "BYTES: 戻り値は Array (index access)")
assert_output("b = \"hi\".bytes\nputs b[0] + b[1]\n",
              "209\n", "BYTES: 要素は Fixnum (加算可能)")
# 元の文字列は破壊されない
assert_output("s = \"abc\"\ns.bytes\nputs s\n", "abc\n", "BYTES: 元 String を破壊しない")
# 改行や非 ASCII バイトを含む文字列も bytes 化される
assert_output("puts \"a\\nb\".bytes\n",       "97\n10\n98\n", "BYTES: 改行込み")

# ---- Integer#chr ----
assert_output("puts 97.chr\n",                "a\n",          "INT_CHR: ASCII 'a'")
assert_output("puts 65.chr\n",                "A\n",          "INT_CHR: 大文字 'A'")
assert_output("puts 48.chr\n",                "0\n",          "INT_CHR: 数字 '0'")
assert_output("puts 32.chr\n",                " \n",          "INT_CHR: 半角スペース")
assert_output("puts 10.chr.bytes\n",          "10\n",         "INT_CHR: \\n を bytes で確認")
assert_output("puts 0.chr.bytes\n",           "0\n",          "INT_CHR: NUL (0)")
assert_output("puts 255.chr.bytes\n",         "255\n",        "INT_CHR: 上限 255")
assert_raises("puts (-1).chr\n",              "INT_CHR: 負数は範囲外で raise")
assert_raises("puts 256.chr\n",               "INT_CHR: 256 は範囲外で raise")

# ---- String#chr ----
assert_output("puts \"abc\".chr\n",           "a\n",          "STR_CHR: 1 文字目を返す")
assert_output("puts \"abc\".chr.bytes\n",     "97\n",         "STR_CHR: 戻り値は 1 文字 String")
assert_output("s = \"hello\"\nputs s.chr\nputs s\n",
              "h\nhello\n", "STR_CHR: 元の文字列を破壊しない")
assert_raises("puts \"\".chr\n",              "STR_CHR: 空文字列は raise")

# ---- bytes + chr で round-trip ----
assert_output("puts \"X\".bytes[0].chr\n",    "X\n",          "ROUND: bytes[0].chr で復元")
assert_output("b = \"abc\".bytes\nputs b[0].chr + b[1].chr + b[2].chr\n",
              "abc\n", "ROUND: 各 byte を chr して結合")

# ---- Object#nil? ----
assert_output("puts nil.nil?\n",              "true\n",       "NIL_Q: nil")
assert_output("puts 1.nil?\n",                "false\n",      "NIL_Q: Fixnum")
assert_output("puts 0.nil?\n",                "false\n",      "NIL_Q: 0")
assert_output("puts \"x\".nil?\n",            "false\n",      "NIL_Q: String")
assert_output("puts \"\".nil?\n",             "false\n",      "NIL_Q: 空 String も非 nil")
assert_output("puts [].nil?\n",               "false\n",      "NIL_Q: 空 Array も非 nil")
assert_output("puts true.nil?\n",             "false\n",      "NIL_Q: true")
assert_output("puts false.nil?\n",            "false\n",      "NIL_Q: false (= nil ではない)")
assert_output("puts :foo.nil?\n",             "false\n",      "NIL_Q: Symbol")
# 引数を渡したら ArgumentError
assert_raises("puts nil.nil?(1)\n",           "NIL_Q: 引数つきは ArgumentError")

# ---- if 条件と組み合わせる ----
nil_q_if = <<~RUBY
  x = nil
  if x.nil?
    puts "is_nil"
  else
    puts "not_nil"
  end
  y = 1
  if y.nil?
    puts "is_nil"
  else
    puts "not_nil"
  end
RUBY
assert_output(nil_q_if, "is_nil\nnot_nil\n", "NIL_Q: if 条件で分岐")

# ---- method 引数経由で nil? を使う (interp.rb 風) ----
nil_q_method = <<~RUBY
  def check(x)
    if x.nil?
      puts "absent"
    else
      puts "present"
    end
  end
  check(nil)
  check(42)
  check("hi")
RUBY
assert_output(nil_q_method, "absent\npresent\npresent\n", "NIL_Q: 引数経由")

# ---- TypeError 系 ----
assert_raises("puts 1.bytes\n",               "TYPE: Integer#bytes は不可")
assert_raises("puts [1,2].bytes\n",           "TYPE: Array#bytes は不可")
assert_raises("puts \"x\".bytes(1)\n",        "TYPE: bytes に引数は不可 (arity 不一致)")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4e)"
exit($fail == 0 ? 0 : 1)
