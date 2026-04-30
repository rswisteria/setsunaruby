$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/lexer'
require 'setsunaruby/parser'
require 'setsunaruby/compiler'
require 'setsunaruby/vm'
require 'stringio'

# 自前 assert (minitest 等に依存しない)
$pass = 0
$fail = 0

def run_source(src)
  tokens = Setsunaruby::Lexer.new(src).tokenize
  prog   = Setsunaruby::Parser.new(tokens).parse_program
  bc     = Setsunaruby::Compiler.new.compile(prog)
  buf    = StringIO.new
  saved  = $stdout
  $stdout = buf
  begin
    Setsunaruby::VM.new(bc).run
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

# ---- 算術 ----
assert_output("puts 1\n",          "1\n",   "整数リテラル")
assert_output("puts -5\n",         "-5\n",  "単項マイナス")
assert_output("puts 1 + 2\n",      "3\n",   "加算")
assert_output("puts 10 - 3\n",     "7\n",   "減算")
assert_output("puts 4 * 5\n",      "20\n",  "乗算")
assert_output("puts 100 / 7\n",    "14\n",  "整数除算")
assert_output("puts 100 % 7\n",    "2\n",   "剰余")
assert_output("puts 2 + 3 * 4\n",  "14\n",  "優先順位 (mul > add)")
assert_output("puts (2 + 3) * 4\n","20\n",  "括弧")
assert_output("puts -(2 + 3)\n",   "-5\n",  "単項マイナス + 括弧")
assert_output("puts 10 - 5 - 2\n", "3\n",   "左結合 (sub)")
assert_output("puts 24 / 4 / 2\n", "3\n",   "左結合 (div)")

# ---- 比較 ----
assert_output("puts 1 == 1\n",  "true\n",  "==")
assert_output("puts 1 == 2\n",  "false\n", "== (false)")
assert_output("puts 1 < 2\n",   "true\n",  "<")
assert_output("puts 2 > 1\n",   "true\n",  ">")
assert_output("puts 3 <= 3\n",  "true\n",  "<=")
assert_output("puts 3 >= 4\n",  "false\n", ">=")

# ---- リテラル ----
assert_output("puts true\n",   "true\n",  "true")
assert_output("puts false\n",  "false\n", "false")
assert_output("puts nil\n",    "\n",      "nil (空行)")

# ---- 異種比較は false (例外にしない) ----
assert_output("puts 1 == true\n",   "false\n", "Fixnum == true")
assert_output("puts nil == false\n","false\n", "nil == false")

# ---- 大きな整数 (LEB128 multi-byte) ----
assert_output("puts 1000000\n",   "1000000\n",   "100万")
assert_output("puts -1000000\n",  "-1000000\n",  "-100万")
assert_output("puts 1000000 * 1000000\n", "1000000000000\n", "兆")

# ---- 複数文 ----
assert_output("puts 1\nputs 2\n", "1\n2\n", "複数文")
assert_output("\n\nputs 1\n\nputs 2\n\n", "1\n2\n", "空行の混在")

# ---- コメント ----
assert_output("puts 1 # comment\n# whole-line\nputs 2\n", "1\n2\n", "コメント")
assert_output("# 日本語コメント\nputs 1\n", "1\n", "マルチバイトコメント")
assert_output("puts 1 # 末尾日本語\nputs 2\n", "1\n2\n", "行末マルチバイトコメント")

# ---- エラー系 ----
assert_raises("puts 1 / 0\n",     "ゼロ除算")
assert_raises("puts 1 / (1 - 1)\n","ゼロ除算 (式)")
assert_raises("puts true + 1\n",  "型エラー (bool + int)")
assert_raises("puts 1 < 2 < 3\n", "比較演算子の連鎖禁止")
assert_raises("1 + 2\n",          "puts なしの文")
assert_raises("puts (1 + 2\n",    "閉じ括弧不足")
assert_raises("puts 1 ++ 2\n",    "二重演算子")

# ---- まとめ ----
puts ""
puts "#{$pass} passed, #{$fail} failed"
exit($fail == 0 ? 0 : 1)
