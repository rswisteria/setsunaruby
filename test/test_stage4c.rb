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

# ---- puts <symbol> 基本 ----
assert_output("puts :foo\n",           "foo\n",  "PUTS: :foo は \"foo\"")
assert_output("puts :a\n",             "a\n",    "PUTS: 1 文字 symbol")
assert_output("puts :int_lit\n",       "int_lit\n", "PUTS: 下線入り")
assert_output("puts :Foo\n",           "Foo\n",  "PUTS: 大文字始まり")
assert_output("puts :foo?\n",          "foo?\n", "PUTS: ? 付き predicate symbol")
assert_output("puts :bar!\n",          "bar!\n", "PUTS: ! 付き destructive symbol")

# ---- == / != は obj_id 比較で動く ----
assert_output("puts :foo == :foo\n",   "true\n",  "EQ: 同名 symbol は等価")
assert_output("puts :foo == :bar\n",   "false\n", "EQ: 異名 symbol は非等価")
assert_output("puts :foo != :foo\n",   "false\n", "NEQ: 同名 symbol")
assert_output("puts :foo != :bar\n",   "true\n",  "NEQ: 異名 symbol")
assert_output("puts :foo? == :foo?\n", "true\n",  "EQ: predicate symbol は intern される")
assert_output("puts :foo? == :foo\n",  "false\n", "EQ: predicate と通常名は別 symbol")

# ---- 異型比較は常に false (Symbol は単独タグ空間) ----
assert_output("puts :foo == \"foo\"\n",  "false\n", "EQ: :foo と \"foo\" は別型")
assert_output("puts :foo == 1\n",        "false\n", "EQ: :foo と Fixnum は別型")
assert_output("puts :foo == nil\n",      "false\n", "EQ: :foo と nil は別型")
assert_output("puts :foo == true\n",     "false\n", "EQ: :foo と true は別型")
assert_output("puts :foo == false\n",    "false\n", "EQ: :foo と false は別型")

# ---- truthy: Symbol は常に truthy ----
assert_output("if :foo\n  puts \"yes\"\nelse\n  puts \"no\"\nend\n",
              "yes\n", "TRUTH: Symbol は truthy")
assert_output("puts !:foo\n",   "false\n", "TRUTH: !:foo は false")
assert_output("puts !!:foo\n",  "true\n",  "TRUTH: !!:foo は true")

# ---- 変数代入を経由しても intern 共有される ----
assert_output("x = :tag\nputs x == :tag\n", "true\n", "INTERN: 変数経由でも同 id")
assert_output("x = :tag\ny = :tag\nputs x == y\n", "true\n", "INTERN: 別出現も同 id")

# ---- 配列要素として保持できる (obj_id がそのまま入る) ----
assert_output("a = [:a, :b, :c]\nputs a[1]\n", "b\n", "ARR: 配列内 symbol")
assert_output("a = [:a, :b]\nputs a\n",        "a\nb\n", "ARR: puts で 1 行ずつ")

# ---- method 引数経由 ----
asym_method = <<~RUBY
  def tag(t)
    if t == :ok
      puts "fine"
    elsif t == :err
      puts "broken"
    end
  end
  tag(:ok)
  tag(:err)
RUBY
assert_output(asym_method, "fine\nbroken\n", "METHOD: 引数 symbol で分岐")

# ---- interp.rb の Symbol 参照箇所が parse できる (M1 のサブゴール) ----
# AST kind タグ風の使い方が構文エラーなしで通ることだけ確認 (実行不要)。
interp_rb_style = <<~RUBY
  k = :int_lit
  if k == :int_lit
    puts "matched"
  elsif k == :bin_op
    puts "binop"
  end
RUBY
assert_output(interp_rb_style, "matched\n", "INTERP: kind tag 風コード")

# ---- 字句エラー ----
assert_raises("puts :\n",       "Lexer: : の直後に識別子がないと字句エラー")
assert_raises("puts : foo\n",   "Lexer: : の直後にスペースは不可")

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4c)"
exit($fail == 0 ? 0 : 1)
