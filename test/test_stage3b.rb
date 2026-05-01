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

# ---- 配列リテラル + length ----
# Ruby の puts は配列を要素ごとに別行で出力する
assert_output("a = [1, 2, 3]\nputs a.length\n",       "3\n",          "[1,2,3].length")
assert_output("a = []\nputs a.length\n",              "0\n",          "空配列の length")
assert_output("a = [42]\nputs a.length\n",            "1\n",          "1 要素の length")
assert_output("a = [1, 2, 3]\nputs a\n",              "1\n2\n3\n",    "puts は要素別行")
assert_output("a = []\nputs a\n",                     "",             "puts 空配列は何も出さない")

# ---- index 読み込み ----
assert_output("a = [10, 20, 30]\nputs a[0]\n",        "10\n",         "a[0]")
assert_output("a = [10, 20, 30]\nputs a[2]\n",        "30\n",         "末尾要素")
assert_output("a = [10, 20, 30]\nputs a[1]\n",        "20\n",         "中央")
# 範囲外 (positive) は nil (Ruby と同じ)。puts nil は空行。
assert_output("a = [10, 20, 30]\nputs a[5]\n",        "\n",           "範囲外 → nil")
# 計算式が index
assert_output("a = [10, 20, 30]\ni = 1\nputs a[i + 1]\n", "30\n",     "index に式")

# ---- index 書き込み ----
assert_output("a = [1, 2, 3]\na[1] = 99\nputs a\n",   "1\n99\n3\n",   "a[i] = v")
assert_output("a = [0, 0, 0]\na[0] = 7\na[2] = 9\nputs a\n", "7\n0\n9\n", "複数要素を書換")
# 代入式は値を返す
assert_output("a = [0]\nputs (a[0] = 42)\n",          "42\n",         "代入式の値")

# ---- << push 多相 ----
assert_output("a = []\na << 1\na << 2\na << 3\nputs a\n", "1\n2\n3\n", "<<: array push")
assert_output("a = []\na << 1\nputs a.length\n",      "1\n",          "<< して length 反映")
# String × String の <<: Stage 3a の挙動が壊れていないこと
assert_output("s = \"abc\"\ns << \"de\"\nputs s\n",   "abcde\n",      "<<: string (3a 互換)")
# 共有参照: a と b が同じ array を指していて << で両方更新される
assert_output("a = []\nb = a\nb << 7\nputs a\n",      "7\n",          "<<: 共有参照")

# ---- chain ----
assert_output("a = [] << 1 << 2 << 3\nputs a\n",      "1\n2\n3\n",    "<<: chain")
# postfix 連鎖
assert_output("puts [10, 20, 30][1]\n",                "20\n",         "literal[1]")
assert_output("puts [1, 2, 3].length\n",               "3\n",          "literal.length")

# ---- 異種要素 ----
assert_output("a = [1, \"x\", true, nil]\nputs a.length\n", "4\n",    "異種要素 length")
assert_output("a = [1, \"x\", true, nil]\nputs a\n",   "1\nx\ntrue\n\n", "異種要素 puts")
# 配列の要素として配列 (ネスト)
assert_output("a = [[1, 2], [3, 4]]\nputs a.length\n", "2\n",         "ネスト配列 length")
assert_output("a = [[1, 2], [3, 4]]\nputs a\n",        "1\n2\n3\n4\n", "ネスト配列 puts (再帰展開)")
assert_output("a = [[1, 2], [3, 4]]\nputs a[0][1]\n",  "2\n",          "a[i][j] (chain index)")

# ---- ループ + array ----
sum_via_array = <<~RUBY
  a = []
  i = 0
  while i < 5
    a << i + 1
    i = i + 1
  end
  s = 0
  j = 0
  while j < a.length
    s = s + a[j]
    j = j + 1
  end
  puts s
RUBY
assert_output(sum_via_array, "15\n", "ループで配列構築 + 走査合計")

# ---- メソッド戻り値 ----
make_arr = <<~RUBY
  def make
    [10, 20, 30]
  end
  a = make
  puts a[1]
  puts a.length
RUBY
assert_output(make_arr, "20\n3\n", "メソッドが配列を返す")

# ---- 文字列との混在 ----
assert_output("a = [\"hello\", \"world\"]\nputs a\n", "hello\nworld\n", "文字列要素")
assert_output("a = []\na << \"x\"\na << \"y\"\nputs a\n", "x\ny\n",     "文字列を push")

# ---- エラー系 ----
assert_raises("a = [1, 2]\nputs a[-1]\n",                    "負 index は Stage 3b スコープ外")
assert_raises("a = [1, 2]\na[5] = 99\n",                     "範囲外への代入")
assert_raises("puts 1.length\n",                              "Fixnum.length は不可")
assert_raises("puts \"abc\".length\n",                        "String.length は Stage 3b 未対応")
assert_raises("a = 1\nputs a[0]\n",                           "Fixnum[0] は不可")
assert_raises("a = [1, 2]\nputs a[\"x\"]\n",                  "index に Integer 以外")
assert_raises("puts 1 << 1\n",                                "Fixnum << Fixnum はエラー (Stage 3a と同じ)")
assert_raises("puts [1, 2\n",                                  "閉じ ] なし")
# 末尾カンマは Ruby と同じく許容 (`[1, 2,]` は `[1, 2]` と等価)
assert_output("a = [1, 2,]\nputs a.length\n", "2\n",          "末尾カンマは許容")

# ---- 自己参照配列 ----
# `a << a` 自体は成功 (length が 1 になり要素 0 は a 自身)
assert_output("a = []\na << a\nputs a.length\n", "1\n",       "<<: 自己参照配列の length")
# しかし puts は循環参照で深さ上限に達してエラー
assert_raises("a = []\na << a\nputs a\n",                      "循環参照配列の puts はエラー")
# 自己連結 `a << a[0]` 等は問題なし
assert_output("a = [99]\na << a[0]\nputs a\n", "99\n99\n",    "<<: 自己要素 push")

# ---- 大規模配列 ----
big = <<~RUBY
  a = []
  i = 0
  while i < 100
    a << i
    i = i + 1
  end
  puts a.length
  puts a[0]
  puts a[50]
  puts a[99]
RUBY
assert_output(big, "100\n0\n50\n99\n", "100 要素の配列")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3b)"
exit($fail == 0 ? 0 : 1)
