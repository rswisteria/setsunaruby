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

# ---- 基本 ----
assert_output("puts 'hello'\n", "hello\n", "BASIC: puts 'hello'")
assert_output("puts ''\n",      "\n",      "BASIC: puts '' (空文字列)")
assert_output("puts ''.bytes.length\n", "0\n", "BASIC: '' は長さ 0")
assert_output("puts 'a'.bytes.length\n", "1\n", "BASIC: 'a' は長さ 1")

# ---- Issue #58 完了基準 ----
assert_output("puts 'a' == 'a'\n", "true\n", "EQ: 'a' == 'a' は true")
assert_output("puts 'a' == 'b'\n", "false\n", "EQ: 'a' == 'b' は false")
# 'a\nb' は \ + n を解釈せず 4 byte (a, \, n, b)
assert_output("puts 'a\\nb'.bytes\n", "97\n92\n110\n98\n",
              "ESC: 'a\\nb' は \\ と n を別バイトで残す")
# 'it\'s' は \' で ' に解釈、4 byte (i, t, ', s)
assert_output("puts 'it\\'s'.bytes\n", "105\n116\n39\n115\n",
              "ESC: 'it\\'s' は \\' で ' を埋め込む")

# ---- escape 一般 ----
# \\ → \ (1 byte)
assert_output("puts 'a\\\\b'.bytes\n", "97\n92\n98\n",
              "ESC: '\\\\' は \\ 1 byte")
# \t / \r / \0 はそのまま 2 byte (シングルクォートでは解釈しない)
assert_output("puts 'x\\ty'.bytes\n", "120\n92\n116\n121\n",
              "ESC: '\\t' はそのまま \\ + t")
assert_output("puts 'x\\0y'.bytes\n", "120\n92\n48\n121\n",
              "ESC: '\\0' はそのまま \\ + 0")
# 末尾でない \ の単独残し: 'a\b' = a, \, b
assert_output("puts 'a\\b'.bytes\n", "97\n92\n98\n",
              "ESC: '\\b' は \\ + b そのまま")

# ---- ダブルクォートとの相互運用 ----
assert_output("puts 'abc' == \"abc\"\n", "true\n",
              "INTEROP: 内容が同じなら == は true")
assert_output("puts 'foo' + 'bar'\n", "foobar\n", "INTEROP: '+' で連結")
assert_output("puts 'a' + \"b\"\n", "ab\n", "INTEROP: シングル + ダブル")

# ---- 既存 String API が利く ----
assert_output("s = 'hello'\nputs s.bytes.length\n", "5\n",
              "API: 'hello'.bytes.length = 5")
assert_output("s = 'hi'\ns << 'ya'\nputs s\n", "hiya\n",
              "API: << で破壊的連結")

# ---- 変数代入 + 制御構文 ----
assert_output("s = 'x'\nif s == 'x'\n  puts 'match'\nelse\n  puts 'no'\nend\n",
              "match\n", "FLOW: if 内で == 比較")

# ---- 終端なしエラー ----
assert_raises("puts 'abc\n", "ERR: 終端 ' がない場合は raise")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 5a)"
exit($fail == 0 ? 0 : 1)
