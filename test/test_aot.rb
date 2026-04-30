# AOT 版 (./setsunaruby バイナリ) のリグレッションテスト。
# CRuby 版 (test_stage0.rb) と同じケースを子プロセスで実行して出力比較する。

require 'tempfile'
require 'open3'

AOT_BIN = File.expand_path('../setsunaruby', __dir__)
unless File.executable?(AOT_BIN)
  STDERR.puts "AOT binary not found: #{AOT_BIN}"
  STDERR.puts "Run: make build  (or ~/spinel/spinel bin/setsunaruby.rb -o setsunaruby)"
  exit 1
end

$pass = 0
$fail = 0

def aot_run(src)
  Tempfile.create(['setsunaruby_test', '.rb']) do |f|
    f.write(src)
    f.close
    out, _err, _status = Open3.capture3(AOT_BIN, f.path)
    out
  end
end

def aot_run_status(src)
  Tempfile.create(['setsunaruby_test', '.rb']) do |f|
    f.write(src)
    f.close
    out, _err, status = Open3.capture3(AOT_BIN, f.path)
    [out, status]
  end
end

def assert_output(src, expected, label)
  actual = aot_run(src)
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

def assert_fails(src, label)
  _out, status = aot_run_status(src)
  if !status.success?
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label} (expected failure)"
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
assert_output("puts 2 + 3 * 4\n",  "14\n",  "優先順位")
assert_output("puts (2 + 3) * 4\n","20\n",  "括弧")
assert_output("puts -(2 + 3)\n",   "-5\n",  "単項マイナス + 括弧")

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

# ---- 大きな整数 ----
assert_output("puts 1000000\n",   "1000000\n",   "100万")
assert_output("puts -1000000\n",  "-1000000\n",  "-100万")
assert_output("puts 1000000 * 1000000\n", "1000000000000\n", "兆")

# ---- 複数文 ----
assert_output("puts 1\nputs 2\n", "1\n2\n", "複数文")

# ---- コメント ----
assert_output("puts 1 # comment\n# whole-line\nputs 2\n", "1\n2\n", "コメント")
assert_output("# 日本語コメント\nputs 1\n", "1\n", "マルチバイトコメント")

# ---- エラー系 ----
assert_fails("puts 1 / 0\n",     "ゼロ除算")
assert_fails("puts true + 1\n",  "型エラー")
assert_fails("1 + 2\n",          "puts なしの文")
assert_fails("puts (1 + 2\n",    "閉じ括弧不足")

puts ""
puts "#{$pass} passed, #{$fail} failed (AOT)"
exit($fail == 0 ? 0 : 1)
