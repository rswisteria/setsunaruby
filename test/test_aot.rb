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

# ---- Stage 1: ローカル変数 + 制御構造 ----
assert_output("x = 1\nputs x\n",                                    "1\n",  "代入と参照")
assert_output("x = 1\ny = 2\nputs x + y\n",                         "3\n",  "2変数の演算")
assert_output("if true\n  puts 1\nelse\n  puts 2\nend\n",           "1\n",  "if/else")
assert_output("if false\n  puts 1\nelse\n  puts 2\nend\n",          "2\n",  "if/else (else側)")
assert_output("x = if true then 10 else 20 end\nputs x\n",          "10\n", "if 式")
assert_output("i = 0\nwhile i < 3\n  puts i\n  i = i + 1\nend\n",   "0\n1\n2\n", "while ループ")
assert_output(File.read(File.expand_path('../examples/fizzbuzz.rb', __dir__)),
              (1..30).map { |i|
                if i % 15 == 0 then "-1"
                elsif i % 3 == 0 then "-3"
                elsif i % 5 == 0 then "-5"
                else i.to_s
                end
              }.join("\n") + "\n",
              "FizzBuzz 1-30")

# ---- Stage 2: メソッド定義 + 呼び出し + 再帰 ----
assert_output("def add(a, b)\n  a + b\nend\nputs add(3, 4)\n", "7\n", "メソッド 2 引数")
assert_output("def f\n  42\nend\nputs f\n",                   "42\n", "引数なしメソッド")
assert_output("def sq(x)\n  x * x\nend\nputs sq(7)\n",        "49\n", "メソッド呼び出し (式中)")
fib_aot = <<~RUBY
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end
  puts fib(10)
  puts fib(20)
RUBY
assert_output(fib_aot, "55\n6765\n", "fib(20) 受け入れ条件")
fact_aot = <<~RUBY
  def fact(n)
    if n <= 1
      1
    else
      n * fact(n - 1)
    end
  end
  puts fact(10)
RUBY
assert_output(fact_aot, "3628800\n", "factorial(10)")
ack_aot = <<~RUBY
  def ack(m, n)
    if m == 0
      n + 1
    elsif n == 0
      ack(m - 1, 1)
    else
      ack(m - 1, ack(m, n - 1))
    end
  end
  puts ack(3, 3)
RUBY
assert_output(ack_aot, "61\n", "アッカーマン関数")
tarai_aot = <<~RUBY
  def tarai(x, y, z)
    if x <= y
      y
    else
      tarai(tarai(x - 1, y, z), tarai(y - 1, z, x), tarai(z - 1, x, y))
    end
  end
  puts tarai(6, 3, 0)
RUBY
assert_output(tarai_aot, "6\n", "tarai 関数")
early_aot = <<~RUBY
  def abs(n)
    if n < 0
      return -n
    end
    n
  end
  puts abs(-7)
  puts abs(3)
RUBY
assert_output(early_aot, "7\n3\n", "return で早期離脱")
scope_aot = <<~RUBY
  def f
    x = 99
    x
  end
  x = 1
  puts f
  puts x
RUBY
assert_output(scope_aot, "99\n1\n", "メソッド内ローカルとトップレベルの分離")

# ---- Stage 3a: 文字列 ----
assert_output(%(puts "hello"\n),                      "hello\n",        "STR: ASCII リテラル")
assert_output(%(puts "a\\nb"\n),                      "a\nb\n",         "STR: \\n escape")
assert_output(%(puts "a\\tb"\n),                      "a\tb\n",         "STR: \\t escape")
assert_output(%(puts "foo" + "bar"\n),                "foobar\n",       "STR: + 連結")
assert_output(%(s = "ab" + "cd" + "ef"\nputs s\n),    "abcdef\n",       "STR: + 3 連結")
assert_output(%(s = "abc"\ns << "de"\nputs s\n),      "abcde\n",        "STR: << 拡張")
assert_output(%(a = "abc"\nb = a\na << "X"\nputs b\n), "abcX\n",        "STR: << 共有参照")
assert_output(%(puts "abc" == "abc"\n),               "true\n",         "STR: == 同一内容")
assert_output(%(puts "abc" == "abd"\n),               "false\n",        "STR: == 異内容")
assert_output(%(puts "1" == 1\n),                     "false\n",        "STR: == 異型は false")
assert_output(File.read(File.expand_path('../examples/string.rb', __dir__)),
              "hello, setsunaruby\ntab\there\nline1\nline2\nStage 3a\n*****\nok\n",
              "examples/string.rb")

# ---- Stage 3b: 配列 ----
assert_output("a = [1, 2, 3]\nputs a.length\n",       "3\n",          "ARR: literal + length")
assert_output("a = []\nputs a.length\n",              "0\n",          "ARR: empty length")
assert_output("a = [10, 20, 30]\nputs a[1]\n",        "20\n",         "ARR: index get")
assert_output("a = [1, 2, 3]\na[1] = 99\nputs a\n",   "1\n99\n3\n",   "ARR: index set + puts")
assert_output("a = []\na << 1\na << 2\nputs a\n",     "1\n2\n",       "ARR: << push")
assert_output("a = [1, 2]\nputs a\n",                 "1\n2\n",       "ARR: puts requires elements per line")
assert_output("a = [[1, 2], [3, 4]]\nputs a[0][1]\n", "2\n",          "ARR: nested index")
assert_output(File.read(File.expand_path('../examples/array.rb', __dir__)),
              "3\n5\n10\n50\n10\n20\n999\n40\n50\n3\n2\n3\n5\n1\ntwo\ntrue\n\n9\n",
              "examples/array.rb")

# ---- Stage 3c.1: ブロック (each / times) ----
assert_output("3.times do |i|\n  puts i\nend\n", "0\n1\n2\n",       "BLK: times")
assert_output("[10, 20].each do |x|\n  puts x\nend\n", "10\n20\n",  "BLK: each")
assert_output("s = 0\n5.times do |i|\n  s = s + i\nend\nputs s\n", "10\n", "BLK: 集計 (closure read)")
assert_output(File.read(File.expand_path('../examples/each.rb', __dir__)),
              "0\n1\n2\n10\n20\n30\n15\n1\n4\n9\n16\n25\n100\n",
              "examples/each.rb")

# ---- Stage 3c.2: 一般 yield ----
yield_basic = <<~RUBY
  def emit(x)
    yield x
  end
  emit(42) do |v|
    puts v
  end
RUBY
assert_output(yield_basic, "42\n", "YIELD: 引数 1 つ")

yield_loop = <<~RUBY
  def my_each(arr)
    i = 0
    while i < arr.length
      yield arr[i]
      i = i + 1
    end
  end
  s = 0
  my_each([1, 2, 3, 4, 5]) do |v|
    s = s + v
  end
  puts s
RUBY
assert_output(yield_loop, "15\n", "YIELD: closure 経由の集計")

assert_output(File.read(File.expand_path('../examples/yield.rb', __dir__)),
              "10\n20\n30\n2\n4\n6\n8\nhi\nhi\nhi\n15\n",
              "examples/yield.rb")
assert_fails("def f\n  yield\nend\nf\n", "YIELD: block なしで raise")

# ---- Stage 3c.3: block_given? / Array#map / 中括弧ブロック ----
assert_output("def f\n  puts block_given?\nend\nf\n", "false\n", "BLK?: false")
assert_output("def f\n  puts block_given?\nend\nf do\nend\n", "true\n", "BLK?: true")
assert_output("puts [1, 2, 3].map { |x| x + 100 }\n", "101\n102\n103\n", "MAP: 中括弧 + map")
assert_output("3.times { |i| puts i }\n", "0\n1\n2\n", "中括弧: times")
assert_output(File.read(File.expand_path('../examples/map.rb', __dir__)),
              "1\n4\n9\n16\n25\n1\n2\n3\nHello, world\nWelcome, setsunaruby!\n101\n102\n103\n",
              "examples/map.rb")

# ---- Stage 3d.1: クラス / @var / self / .new ----
assert_output("class C\n  def hi\n    42\n  end\nend\nputs C.new.hi\n", "42\n", "CLS: 引数なし method")
assert_output("class C\n  def add(a, b)\n    a + b\n  end\nend\nputs C.new.add(3, 4)\n", "7\n", "CLS: 引数あり method")
assert_output("class C\n  def set(n)\n    @n = n\n  end\n  def get\n    @n\n  end\nend\nc = C.new\nc.set(99)\nputs c.get\n",
              "99\n", "CLS: @var read/write")
assert_output(File.read(File.expand_path('../examples/class.rb', __dir__)),
              "3\n1\n3\n12\n24\n15\n2\n4\n6\n",
              "examples/class.rb")

# ---- Stage 3d.2: initialize / .new(args) ----
assert_output(<<~RUBY, "12\n", "INIT: 2 引数 initialize")
  class R
    def initialize(w, h)
      @w = w
      @h = h
    end
    def area
      @w * @h
    end
  end
  puts R.new(3, 4).area
RUBY
assert_fails(<<~RUBY, "INIT: argc mismatch エラー")
  class C
    def initialize(x)
    end
  end
  C.new
RUBY
assert_output(File.read(File.expand_path('../examples/initialize.rb', __dir__)),
              "25\n3\n4\n1\n2\n6\n24\n120\n3\na\nb\nc\n",
              "examples/initialize.rb")

# ---- Stage 3d.4: 継承 ----
assert_output("class A\n  def f\n    \"A\"\n  end\nend\nclass B < A\nend\nputs B.new.f\n",
              "A\n", "INH: 親 method を子から呼ぶ")
assert_output("class A\n  def f\n    \"A\"\n  end\nend\nclass B < A\n  def f\n    \"B\"\n  end\nend\nputs B.new.f\nputs A.new.f\n",
              "B\nA\n", "INH: 子で override")
assert_output(File.read(File.expand_path('../examples/inherit.rb', __dir__)),
              "Generic says ...\nRex says Woof\nMia says Meow\nTiny says yip\n11\n",
              "examples/inherit.rb")
assert_fails("class B < Undef\nend\n", "INH: 未定義の親")

# ---- Stage 3d.5: super + each/times/map class table 化 ----
assert_output("class A\n  def f\n    \"A\"\n  end\nend\nclass B < A\n  def f\n    super + \"B\"\n  end\nend\nputs B.new.f\n",
              "AB\n", "SUPER: bare super で親の同名 method")
assert_output("class A\n  def f(x)\n    x + 1\n  end\nend\nclass B < A\n  def f(x)\n    super(x * 10)\n  end\nend\nputs B.new.f(2)\n",
              "21\n", "SUPER: 明示 args")
assert_output(File.read(File.expand_path('../examples/super.rb', __dir__)),
              "Alice\n[VIP] Bob\nABC\n3\n4\n5\n6\n2\n4\n6\n3\n1\n4\n9\n16\n",
              "examples/super.rb")
assert_output("class S\n  def each\n    yield 99\n  end\nend\nS.new.each do |x|\n  puts x\nend\n",
              "99\n", "EACH: ユーザ class の each も class table dispatch")
assert_fails("super\n", "SUPER: top-level は compile error")

# ---- Stage 3e: 例外処理 ----
assert_output("begin\n  raise \"x\"\nrescue => e\n  puts e.message\nend\n",
              "x\n", "EXC: raise + rescue")
assert_output("class E < StandardError\nend\nbegin\n  raise E.new(\"y\")\nrescue StandardError => e\n  puts e.message\nend\n",
              "y\n", "EXC: 継承クラスを親で捕捉")
assert_output("def f\n  begin\n    raise \"a\"\n  ensure\n    puts \"e\"\n  end\nend\nbegin\n  f\nrescue => e\n  puts e.message\nend\n",
              "e\na\n", "EXC: ensure 後に再 raise")
assert_output(File.read(File.expand_path('../examples/exception.rb', __dir__)),
              "boom\nhello\nvalidation failed: input is empty\nwork\ncleanup\ncleanup\ngot: boom\n1\ninterrupted: stop at 2\nauth: forbidden\n",
              "examples/exception.rb")
assert_fails("raise \"unhandled\"\n", "EXC: 未捕捉 raise はプロセスを abort")
assert_fails("begin\n  raise \"x\"\nrescue Undef\n  nil\nend\n", "EXC: 未定義クラスを rescue")
assert_fails("begin\n  1\nend\n", "EXC: rescue/ensure なしの begin はパースエラー")

# ---- Stage 4a: ビット/論理演算 ----
assert_output("puts 1 << 3\n", "8\n", "BIT: 整数左シフト")
assert_output("puts 8 >> 2\n", "2\n", "BIT: 整数右シフト")
assert_output("puts 12 & 10\n", "8\n", "BIT: AND")
assert_output("puts 12 | 10\n", "14\n", "BIT: OR")
assert_output("puts 12 ^ 10\n", "6\n", "BIT: XOR")
assert_output("puts ~0\n", "-1\n", "BIT: NOT")
assert_output("puts 1 != 2\n", "true\n", "LOG: !=")
assert_output("puts !true\n", "false\n", "LOG: !")
assert_output("puts true && false\n", "false\n", "LOG: &&")
assert_output("puts nil || 7\n", "7\n", "LOG: || rhs を返す")
assert_output("puts 1 + 2 << 1\n", "6\n", "PRI: + > <<")
assert_output("puts 1 << 2 | 1\n", "5\n", "PRI: << > | (Ruby 互換)")
assert_output(File.read(File.expand_path('../examples/bitops.rb', __dir__)),
              "8\n2\n8\n14\n6\n-1\n14\n15\nfalse\ntrue\ntrue\nfalse\ntrue\nfalse\ntrue\n7\n0\n6\n5\ntrue\n327683\n",
              "examples/bitops.rb")

# ---- Stage GC-1: GC 動作下での examples 不変 ----
assert_output(File.read(File.expand_path('../examples/gc.rb', __dir__)),
              "done: xy\nxy\nxy\n",
              "examples/gc.rb (GC-1: 大量 alloc + drop)")

# ---- エラー系 ----
assert_fails(%(puts "a" + 1\n),  "STR: + 型エラー")
# Stage 4a 以降は `Fixnum << Fixnum` が整数左シフトに dispatch される。
# 残るは混合型のエラーのみ。
assert_fails(%(puts "a" << 1\n), "STR: String << Fixnum は依然エラー")
assert_fails("a = [1, 2]\nputs a[-1]\n",  "ARR: 負 index は Stage 3b スコープ外")
assert_fails("puts 1.length\n",            "ARR: Fixnum.length は不可")
assert_fails("puts 1 / 0\n",     "ゼロ除算")
assert_fails("puts true + 1\n",  "型エラー")
assert_fails("puts (1 + 2\n",    "閉じ括弧不足")
assert_fails("puts y\n",          "未定義変数")
assert_fails("def f(a)\n  a\nend\nputs f(1, 2)\n", "引数 過剰 (Stage 2)")
assert_fails("return 1\n",                          "トップレベル return 禁止 (Stage 2)")

puts ""
puts "#{$pass} passed, #{$fail} failed (AOT)"
exit($fail == 0 ? 0 : 1)
