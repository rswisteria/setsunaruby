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

# ---- 基本: 引数なし / 1 引数 / 2 引数 ----
assert_output("def f\n  42\nend\nputs f\n",                "42\n",  "引数なし (() 省略)")
assert_output("def f()\n  42\nend\nputs f()\n",            "42\n",  "引数なし () 付き")
assert_output("def square(x)\n  x * x\nend\nputs square(7)\n",
              "49\n", "1 引数")
assert_output("def add(a, b)\n  a + b\nend\nputs add(3, 4)\n",
              "7\n",  "2 引数")
assert_output("def add3(a, b, c)\n  a + b + c\nend\nputs add3(1, 2, 3)\n",
              "6\n",  "3 引数")

# ---- 戻り値: 暗黙的に最後の式 ----
assert_output("def f(x)\n  y = x + 1\n  y * 2\nend\nputs f(10)\n",
              "22\n", "ローカル変数経由で戻す")
assert_output("def f(x)\n  if x > 0\n    1\n  else\n    -1\n  end\nend\nputs f(5)\nputs f(-3)\n",
              "1\n-1\n", "if 式の値が戻り値")

# ---- return: 早期離脱 ----
assert_output("def abs(n)\n  if n < 0\n    return -n\n  end\n  n\nend\nputs abs(-7)\nputs abs(3)\n",
              "7\n3\n", "return で早期離脱")
assert_output("def f\n  return 99\nend\nputs f\n", "99\n", "return 単独")

# ---- 再帰: 階乗 ----
fact_src = <<~RUBY
  def fact(n)
    if n <= 1
      1
    else
      n * fact(n - 1)
    end
  end
  puts fact(0)
  puts fact(1)
  puts fact(5)
  puts fact(10)
RUBY
assert_output(fact_src, "1\n1\n120\n3628800\n", "再帰 階乗")

# ---- 受け入れ条件: fib(20) ----
fib_src = <<~RUBY
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end
  puts fib(0)
  puts fib(1)
  puts fib(10)
  puts fib(20)
RUBY
assert_output(fib_src, "0\n1\n55\n6765\n", "再帰 fib(20) [受け入れ条件]")

# ---- 受け入れ条件: アッカーマン (深い再帰) ----
ack_src = <<~RUBY
  def ack(m, n)
    if m == 0
      n + 1
    elsif n == 0
      ack(m - 1, 1)
    else
      ack(m - 1, ack(m, n - 1))
    end
  end
  puts ack(0, 0)
  puts ack(2, 3)
  puts ack(3, 3)
RUBY
assert_output(ack_src, "1\n9\n61\n", "アッカーマン [受け入れ条件]")

# ---- 受け入れ条件: tarai 関数 ----
tarai_src = <<~RUBY
  def tarai(x, y, z)
    if x <= y
      y
    else
      tarai(tarai(x - 1, y, z), tarai(y - 1, z, x), tarai(z - 1, x, y))
    end
  end
  puts tarai(6, 3, 0)
  puts tarai(8, 4, 0)
RUBY
assert_output(tarai_src, "6\n8\n", "tarai 関数 [受け入れ条件]")

# ---- スコープ分離: メソッド内のローカルは外に漏れない ----
assert_output("def f\n  x = 99\n  x\nend\nx = 1\nputs f\nputs x\n",
              "99\n1\n", "メソッド内 x はトップレベル x と独立")

# ---- 値渡し: 呼び出し元の変数は変更されない (再代入不可) ----
assert_output("def inc(n)\n  n = n + 1\n  n\nend\na = 10\nputs inc(a)\nputs a\n",
              "11\n10\n", "値渡し (パラメータ再代入はローカルに留まる)")

# ---- 複数のメソッド ----
multi_src = <<~RUBY
  def double(x)
    x * 2
  end
  def triple(x)
    x * 3
  end
  puts double(5)
  puts triple(5)
  puts double(triple(2))
RUBY
assert_output(multi_src, "10\n15\n12\n", "複数メソッドと相互呼び出し")

# ---- メソッドが他メソッドを呼ぶ (前方参照は不可、後方参照のみ) ----
# 1-pass コンパイラなので「呼び出し時点で定義済みのメソッドのみ呼べる」。
# 相互再帰 (forward reference) は Stage 2 のスコープ外。
chain_src = <<~RUBY
  def double(x)
    x * 2
  end
  def quad(x)
    double(double(x))
  end
  puts quad(3)
  puts quad(quad(2))
RUBY
assert_output(chain_src, "12\n32\n", "後方参照の連鎖呼び出し")

# 前方参照 (定義前のメソッドを参照) はコンパイルエラー。
assert_raises("def f\n  g\nend\ndef g\n  1\nend\nputs f\n", "前方参照は禁止")

# ---- 引数の個数不一致はコンパイル時エラー ----
assert_raises("def f(a, b)\n  a + b\nend\nputs f(1)\n",        "引数 不足")
assert_raises("def f(a)\n  a\nend\nputs f(1, 2)\n",            "引数 過剰")

# ---- 未定義メソッド呼び出しはコンパイル時エラー ----
assert_raises("puts notdef(1)\n", "未定義メソッド呼び出し")

# ---- メソッド外の return は禁止 ----
assert_raises("return 1\n", "トップレベル return 禁止")

# ---- メソッド内 def は禁止 ----
assert_raises("def outer\n  def inner\n    1\n  end\nend\n", "メソッド内 def 禁止")

# ---- メソッド内で if/while も使える ----
loop_src = <<~RUBY
  def sum_to(n)
    s = 0
    i = 1
    while i <= n
      s = s + i
      i = i + 1
    end
    s
  end
  puts sum_to(10)
  puts sum_to(100)
RUBY
assert_output(loop_src, "55\n5050\n", "メソッド内 while ループ")

# ---- 引数式の評価順序 (左→右) ----
assert_output("def add(a, b)\n  a + b\nend\nputs add(1 + 2, 3 * 4)\n",
              "15\n", "引数式の評価")

# ---- メソッド呼び出しを式中で使う ----
assert_output("def sq(x)\n  x * x\nend\nputs sq(3) + sq(4)\n",
              "25\n", "メソッド呼び出しの式中利用 (sq(3)+sq(4)=25)")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 2)"
exit($fail == 0 ? 0 : 1)
