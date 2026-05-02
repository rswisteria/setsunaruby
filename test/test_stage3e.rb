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

def assert_raises_with(src, fragment, label)
  err = nil
  begin
    run_source(src)
  rescue StandardError => e
    err = e
  end
  if err && err.message.include?(fragment)
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  expected fragment: #{fragment.inspect}"
    puts "  actual:            #{err && err.message.inspect}"
  end
end

# ---- 基本: raise + rescue で文字列メッセージ ----
basic_raise = <<~RUBY
  begin
    raise "boom"
  rescue => e
    puts e.message
  end
RUBY
assert_output(basic_raise, "boom\n", "raise \"msg\" → StandardError ラップ + rescue でメッセージ取得")

# ---- raise SomeClass.new("msg") + rescue Class => e ----
class_form = <<~RUBY
  begin
    raise StandardError.new("hi")
  rescue StandardError => e
    puts e.message
  end
RUBY
assert_output(class_form, "hi\n", "raise Class.new(msg) + rescue Class => e")

# ---- ユーザ定義 < StandardError ----
user_class = <<~RUBY
  class MyError < StandardError
  end
  begin
    raise MyError.new("custom")
  rescue MyError => e
    puts e.message
  end
RUBY
assert_output(user_class, "custom\n", "ユーザ定義 < StandardError")

# ---- rescue Class が継承先にマッチ (is_a? semantics) ----
inherit_match = <<~RUBY
  class MyError < StandardError
  end
  begin
    raise MyError.new("x")
  rescue StandardError => e
    puts e.message
  end
RUBY
assert_output(inherit_match, "x\n", "rescue 親クラスで子インスタンスを捕捉")

# ---- 複数 rescue 節 (最初にマッチした節のみ実行) ----
multi_rescue = <<~RUBY
  class A < StandardError
  end
  class B < StandardError
  end
  begin
    raise B.new("hit B")
  rescue A => e
    puts "A: " + e.message
  rescue B => e
    puts "B: " + e.message
  end
RUBY
assert_output(multi_rescue, "B: hit B\n", "複数 rescue 節: マッチした節だけ実行")

# ---- catch-all rescue (クラス指定なし) ----
catch_all = <<~RUBY
  begin
    raise "anything"
  rescue
    puts "caught"
  end
RUBY
assert_output(catch_all, "caught\n", "rescue (catch-all、束縛なし)")

# ---- ensure 成功パス ----
ensure_success = <<~RUBY
  begin
    puts "body"
  ensure
    puts "ensure"
  end
RUBY
assert_output(ensure_success, "body\nensure\n", "ensure 節: 成功パス")

# ---- ensure rescue マッチパス ----
ensure_rescue = <<~RUBY
  begin
    raise "x"
  rescue => e
    puts "rescue " + e.message
  ensure
    puts "ensure"
  end
RUBY
assert_output(ensure_rescue, "rescue x\nensure\n", "ensure 節: rescue マッチ後にも実行")

# ---- ensure 後に再 raise (上位で捕捉) ----
ensure_reraise = <<~RUBY
  def inner
    begin
      raise "from inner"
    ensure
      puts "inner ensure"
    end
  end
  begin
    inner
  rescue => e
    puts "outer: " + e.message
  end
RUBY
assert_output(ensure_reraise, "inner ensure\nouter: from inner\n", "ensure 後に未捕捉例外が外側へ伝播")

# ---- ネストした begin (内側 rescue は外側より先にマッチ) ----
nested = <<~RUBY
  begin
    begin
      raise "inner"
    rescue => e
      puts "inner caught: " + e.message
      raise "rethrown"
    end
  rescue => e
    puts "outer caught: " + e.message
  end
RUBY
assert_output(nested, "inner caught: inner\nouter caught: rethrown\n", "ネスト begin: 内側 rescue 後に再 raise → 外側で捕捉")

# ---- メソッド境界をまたいだ unwind ----
cross_method = <<~RUBY
  def deep
    raise "buried"
  end
  def mid
    deep
    puts "mid unreachable"
  end
  begin
    mid
  rescue => e
    puts "got: " + e.message
  end
RUBY
assert_output(cross_method, "got: buried\n", "深い method 内 raise → caller で捕捉 (cfp unwind)")

# ---- block 内 raise ----
block_raise = <<~RUBY
  def caller_with_block
    yield
    puts "after yield (unreached)"
  end
  begin
    caller_with_block do
      raise "in block"
    end
  rescue => e
    puts "got: " + e.message
  end
RUBY
assert_output(block_raise, "got: in block\n", "block 内 raise → 上位で捕捉 (yield/cfp unwind)")

# ---- rescue body 自体は値を返さない (begin 全体は nil) ----
returns_nil = <<~RUBY
  def f
    begin
      raise "x"
    rescue
      99
    end
  end
  v = f
  if v == nil
    puts "is nil"
  else
    puts v
  end
RUBY
assert_output(returns_nil, "is nil\n", "begin/rescue/ensure 全体の値は nil (Stage 3e 仕様)")

# ---- マッチしない rescue は素通り、ensure 経由で外側へ ----
no_match = <<~RUBY
  class A < StandardError
  end
  class B < StandardError
  end
  def doit
    begin
      raise A.new("a-msg")
    rescue B
      puts "B (unreached)"
    ensure
      puts "ensure ran"
    end
  end
  begin
    doit
  rescue A => e
    puts "outer A: " + e.message
  end
RUBY
assert_output(no_match, "ensure ran\nouter A: a-msg\n", "マッチしない rescue → ensure → 外側で捕捉")

# ---- 未捕捉 raise はプロセスを abort ----
unhandled = <<~RUBY
  raise "uncaught"
RUBY
assert_raises_with(unhandled, "StandardError", "未捕捉 raise は StandardError として abort")

# ---- raise の引数が String/Instance 以外なら型エラー ----
type_err = <<~RUBY
  raise 42
RUBY
assert_raises_with(type_err, "TypeError", "raise に Integer は型エラー")

# ---- begin に rescue/ensure がないとパースエラー ----
parse_err = <<~RUBY
  begin
    1
  end
RUBY
assert_raises_with(parse_err, "rescue または ensure", "begin に rescue/ensure 必須")

# ---- 未定義クラスを rescue するとコンパイルエラー ----
undef_class = <<~RUBY
  begin
    raise "x"
  rescue UndefinedClass
    puts "no"
  end
RUBY
assert_raises_with(undef_class, "未定義", "rescue で未定義クラスはコンパイルエラー")

# ---- ensure-only begin (rescue なし、成功パス) ----
ensure_only = <<~RUBY
  begin
    puts "go"
  ensure
    puts "fin"
  end
RUBY
assert_output(ensure_only, "go\nfin\n", "ensure-only (rescue なし、成功パス)")

# ---- ensure-only begin (rescue なし、unhandled で再 raise) ----
ensure_only_unhandled = <<~RUBY
  def doit
    begin
      raise "x"
    ensure
      puts "fin"
    end
  end
  begin
    doit
  rescue => e
    puts "caught " + e.message
  end
RUBY
assert_output(ensure_only_unhandled, "fin\ncaught x\n", "ensure-only: 未捕捉でも ensure → 外側で捕捉")

# ---- メソッド内の rescue + 通常処理の継続 ----
method_local = <<~RUBY
  def safe_div(a, b)
    begin
      a / b
    rescue
      -1
    end
  end
  puts safe_div(10, 2)
  puts safe_div(10, 0)
RUBY
# Note: VM の ZeroDivisionError は catchable にしない方針なので、これは raise されず
# 普通に CRuby/AOT で死ぬ。テストとしてはこれを確認するために except 経由に変更。
# 代わりに「ユーザ raise + rescue + 通常 path の値返し」のテストにする。
method_value = <<~RUBY
  def maybe_raise(do_raise)
    begin
      if do_raise
        raise "X"
      end
      "ok"
    rescue => e
      "caught"
    end
  end
  puts maybe_raise(false)
  puts maybe_raise(true)
RUBY
# 注: begin/rescue/ensure 全体の値は nil 仕様なので、上の例は両方とも nil で puts ""。
# Stage 3e 仕様のため期待値を nil 出力にする。
assert_output(method_value, "\n\n", "begin/rescue 全体は nil (rescue body の値は捨てる)")

puts "\n#{$pass} passed, #{$fail} failed"
exit($fail == 0 ? 0 : 1)
