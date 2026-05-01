$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/interp'
require 'stringio'
require 'tempfile'

# JIT-1 (ZJIT 風): プロファイル収集 + ホットメソッド検出のテスト。
# - 検出ログは STDERR に出る (test_aot.rb の stdout 比較を壊さないため)
# - 閾値ちょうどで 1 回だけ出る (== 判定なので sentinel フラグ不要)
# - インタプリタの結果は変わらない

$pass = 0
$fail = 0

# log_jit_hot は spinel 互換のため $stderr ではなく STDERR (定数) に書く。
# CRuby で StringIO に向けるには STDERR.reopen が必要だが StringIO は IO ではないので
# Tempfile を経由する。例外時にも Tempfile を確実に削除するため close! は ensure 内。
def run_capture(src)
  out_buf = StringIO.new
  saved_out = $stdout
  $stdout = out_buf
  err_tmp = Tempfile.new('jit_stderr')
  saved_stderr = STDERR.dup
  STDERR.reopen(err_tmp.path, 'w')
  err_str = ""
  begin
    Setsunaruby::Interp.new.run_string(src)
  ensure
    STDERR.flush
    STDERR.reopen(saved_stderr)
    saved_stderr.close
    $stdout = saved_out
    err_str = File.read(err_tmp.path)
    err_tmp.close!
  end
  [out_buf.string, err_str]
end

def assert_eq(actual, expected, label)
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

THRESHOLD = Setsunaruby::Interp::JIT_HOT_THRESHOLD

# ---- 閾値未満: hot 検出ログは出ない ----
src_cold = <<~RUBY
  def f
    1
  end
RUBY
n_cold = THRESHOLD - 1
n_cold.times { src_cold << "f\n" }
src_cold << "puts 0\n"
out, err = run_capture(src_cold)
assert_eq(out, "0\n", "閾値未満 (#{n_cold} 回呼び出し): 出力は変わらない")
assert_eq(err, "",   "閾値未満 (#{n_cold} 回呼び出し): hot ログが出ない")

# ---- 閾値ちょうど: 1 回だけ hot 検出ログ ----
src_hot = <<~RUBY
  def f
    1
  end
RUBY
THRESHOLD.times { src_hot << "f\n" }
src_hot << "puts 0\n"
out, err = run_capture(src_hot)
expected_log = "ZJIT: hot method detected (idx=0)\n"
assert_eq(out, "0\n",        "閾値ちょうど: 出力は変わらない")
assert_eq(err, expected_log, "閾値ちょうど: hot ログが 1 回だけ")

# ---- 閾値の 2 倍: hot ログは依然として 1 回だけ (== 判定の確認) ----
src_overshoot = <<~RUBY
  def f
    1
  end
RUBY
n_overshoot = THRESHOLD * 2
n_overshoot.times { src_overshoot << "f\n" }
src_overshoot << "puts 0\n"
out, err = run_capture(src_overshoot)
assert_eq(out, "0\n",        "#{n_overshoot} 回呼び出し: 出力は変わらない")
assert_eq(err, expected_log, "#{n_overshoot} 回呼び出し: hot ログは 1 回だけ")

# ---- 再帰 fib: 既存ケースの結果と一致しつつ hot 検出が起きる ----
fib_src = <<~RUBY
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end
  puts fib(10)
RUBY
out, err = run_capture(fib_src)
assert_eq(out, "55\n",       "fib(10) 結果は不変")
assert_eq(err, expected_log, "fib(10) で fib (idx=0) が hot 検出")

# ---- 複数メソッドが個別に hot 検出される ----
src_multi = <<~RUBY
  def f
    1
  end
  def g
    2
  end
RUBY
THRESHOLD.times { src_multi << "f\n" }
THRESHOLD.times { src_multi << "g\n" }
src_multi << "puts 0\n"
out, err = run_capture(src_multi)
expected_multi = "ZJIT: hot method detected (idx=0)\nZJIT: hot method detected (idx=1)\n"
assert_eq(out, "0\n",          "複数メソッド: 出力は変わらない")
assert_eq(err, expected_multi, "複数メソッド: 各 idx で hot 検出が 1 回ずつ")

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT-1)"
exit($fail == 0 ? 0 : 1)
