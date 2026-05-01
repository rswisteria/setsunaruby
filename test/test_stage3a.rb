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

# ---- リテラル + puts ----
assert_output(%(puts "hello"\n),                "hello\n",        "ASCII リテラル")
assert_output(%(puts ""\n),                     "\n",             "空文字列 (puts は改行のみ)")
assert_output(%(puts "abc def"\n),              "abc def\n",      "空白を含む")
assert_output(%(puts "日本語"\n),                "日本語\n",        "マルチバイト (UTF-8 透過)")

# ---- escape ----
assert_output(%(puts "a\\nb"\n),                "a\nb\n",         "改行 \\n")
assert_output(%(puts "a\\tb"\n),                "a\tb\n",         "タブ \\t")
assert_output(%(puts "a\\\\b"\n),               "a\\b\n",         "バックスラッシュ \\\\")
assert_output(%(puts "a\\"b"\n),                "a\"b\n",         "ダブルクォート \\\"")
assert_output(%(puts "x\\rY"\n),                "x\rY\n",         "復帰 \\r")

# ---- 連結 + ----
assert_output(%(puts "foo" + "bar"\n),          "foobar\n",       "+: 単純連結")
assert_output(%(s = "ab" + "cd" + "ef"\nputs s\n), "abcdef\n",    "+: 3 連結")
assert_output(%(a = "x"\nb = "y"\nputs a + b\n), "xy\n",          "+: 変数同士")
assert_output(%(a = "x"\nb = a + a\nputs a\nputs b\n), "x\nxx\n", "+: 元文字列は変化しない (immutable concat)")

# ---- 比較 == ----
assert_output(%(puts "abc" == "abc"\n),         "true\n",         "==: 値比較 (同一内容)")
assert_output(%(puts "abc" == "abd"\n),         "false\n",        "==: 値比較 (異内容)")
assert_output(%(puts "abc" == "ab"\n),          "false\n",        "==: 長さ違い")
assert_output(%(puts "" == ""\n),                "true\n",         "==: 空 vs 空")
assert_output(%(a = "x" + "y"\nb = "xy"\nputs a == b\n), "true\n", "==: 構築物 vs リテラル")
# 多相比較: 異なる型は false
assert_output(%(puts "1" == 1\n),                "false\n",        "==: String vs Fixnum (異型)")
assert_output(%(puts 1 == 1\n),                  "true\n",         "==: Fixnum 同士 (既存と同じ)")

# ---- 連結 << ----
assert_output(%(s = "abc"\ns << "de"\nputs s\n),               "abcde\n",   "<<: 単純拡張")
assert_output(%(s = "abc"\ns << "de"\ns << "fg"\nputs s\n),    "abcdefg\n", "<<: 連続")
# Ruby semantics: << は mutating で、別変数からも見える
assert_output(%(a = "abc"\nb = a\na << "X"\nputs b\n),          "abcX\n",   "<<: 共有変数からも変更が見える")
# << は self を返すので chain 可能
assert_output(%(s = "" << "a" << "b" << "c"\nputs s\n),         "abc\n",    "<<: 戻り値を chain")

# ---- 演算子優先順位 ----
# `<<` は + より低い: `"a" + "b" << "c"` → `("a"+"b") << "c"`
# 1 つ目のオペランドはリテラル "a" + "b" の結果 (新規 heap)、それを <<= で in-place 拡張
assert_output(%(puts "a" + "b" << "c"\n),                       "abc\n",    "優先順位: + は << より高い")

# ---- if/while で文字列条件は truthy ----
assert_output(%(if "x"\n  puts "yes"\nelse\n  puts "no"\nend\n), "yes\n",   "文字列は truthy")

# ---- メソッドの戻り値が文字列 (Stage 2 連携) ----
greet = <<~RUBY
  def greet(name)
    "Hello, " + name
  end
  puts greet("world")
RUBY
assert_output(greet, "Hello, world\n", "メソッドが String を返す")

# ---- 引数として文字列 ----
echo = <<~RUBY
  def echo(s)
    s
  end
  puts echo("ping")
RUBY
assert_output(echo, "ping\n", "メソッド引数が String")

# ---- ループ内で文字列を組み立て ----
build = <<~RUBY
  s = "x"
  i = 0
  while i < 3
    s = s + "o"
    i = i + 1
  end
  puts s
RUBY
assert_output(build, "xooo\n", "while で +=「相当」 (s = s + ...)")

build_lshift = <<~RUBY
  s = ""
  i = 0
  while i < 4
    s << "*"
    i = i + 1
  end
  puts s
RUBY
assert_output(build_lshift, "****\n", "while で << で in-place 拡張")

# ---- 自己連結 ----
# heap_str_concat / heap_str_append_bang は read 元と write 先が同じスロットになっても
# 「ll/rl とソース start を先に確定してから @str_pool 末尾に append」順なので安全。
assert_output(%(s = "ab"\nputs s + s\n),                "abab\n",   "+: 自己連結 (s + s)")
assert_output(%(s = "xy"\ns << s\nputs s\n),            "xyxy\n",   "<<: 自己 append (s << s)")

# ---- リテラル独立性 ----
# Ruby の semantics: 同じソース上の "abc" でも実行時には別オブジェクト。
# << で変更しても他のリテラル PUSH は影響を受けない。
indep = <<~RUBY
  i = 0
  while i < 3
    s = "ab"
    s << "X"
    puts s
    i = i + 1
  end
RUBY
assert_output(indep, "abX\nabX\nabX\n", "ループ毎にリテラルから新 String を確保 (独立性)")

# ---- 型エラー ----
assert_raises(%(puts "a" + 1\n),      "+: String + Fixnum はエラー")
assert_raises(%(puts 1 + "a"\n),      "+: Fixnum + String はエラー")
assert_raises(%(puts "a" << 1\n),     "<<: String << Fixnum はエラー")
assert_raises(%(puts 1 << 1\n),       "<<: Fixnum << Fixnum はエラー (Stage 3a スコープ外)")

# ---- 終端なしリテラル ----
assert_raises(%(puts "abc\n),          "終端なし \"")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 3a)"
exit($fail == 0 ? 0 : 1)
