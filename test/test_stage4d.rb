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

# ---- pop の基本動作 ----
assert_output("a = [1, 2, 3]\nputs a.pop\n", "3\n", "POP: 末尾要素を返す")
assert_output("a = [1, 2, 3]\na.pop\nputs a.length\n", "2\n", "POP: 配列長が 1 減る")
assert_output("a = [1, 2, 3]\na.pop\nputs a[0]\nputs a[1]\n",
              "1\n2\n", "POP: 残った要素は無傷")
assert_output("a = [1, 2, 3]\na.pop\na.pop\nputs a[0]\nputs a.length\n",
              "1\n1\n", "POP: 連続適用")

# ---- pop の戻り値が値そのものとして使える ----
assert_output("a = [10, 20, 30]\nx = a.pop\nputs x\n", "30\n", "POP: 戻り値を変数に")
assert_output("a = [1, 2, 3]\nputs a.pop + a.pop\n",   "5\n",  "POP: 2 回の戻り値を加算")

# ---- 空配列なら nil (Object#nil? は #43 / Stage 4e で実装、現段階は puts 出力で確認) ----
assert_output("a = []\nputs a.pop\n", "\n", "POP: 空配列の戻り値を puts (nil → 空行)")
# pop しても配列長は 0 のまま (負にならない)
assert_output("a = []\na.pop\nputs a.length\n", "0\n", "POP: 空配列でも長さ 0 のまま")

# ---- last の基本動作 ----
assert_output("a = [1, 2, 3]\nputs a.last\n",            "3\n", "LAST: 末尾要素を返す")
assert_output("a = [1, 2, 3]\na.last\nputs a.length\n",  "3\n", "LAST: 配列を変更しない")
assert_output("a = [1, 2, 3]\nputs a.last\nputs a.last\n",
              "3\n3\n", "LAST: 連続呼び出しも同じ値")
assert_output("a = []\nputs a.last\n",                   "\n",  "LAST: 空配列は nil")

# ---- pop の後の last は新しい末尾 ----
assert_output("a = [1, 2, 3]\na.pop\nputs a.last\n", "2\n", "MIX: pop 後の last は前の末尾")

# ---- 文字列配列でも動く ----
assert_output("a = [\"x\", \"y\", \"z\"]\nputs a.pop\nputs a.length\nputs a.last\n",
              "z\n2\ny\n", "STR: 文字列配列での pop/last")

# ---- pop + << で stack 的に使える ----
assert_output("a = []\na << 1\na << 2\na << 3\nputs a.pop\nputs a.pop\nputs a.pop\n",
              "3\n2\n1\n", "STACK: push (<<) と pop で LIFO")

# ---- Array ではない receiver は TypeError ----
assert_raises("x = 1\nputs x.pop\n",     "TYPE: Integer#pop は TypeError")
assert_raises("x = \"a\"\nputs x.pop\n", "TYPE: String#pop は TypeError")
assert_raises("x = 1\nputs x.last\n",    "TYPE: Integer#last は TypeError")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4d)"
exit($fail == 0 ? 0 : 1)
