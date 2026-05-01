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

def assert_includes(haystack, needle, label)
  if haystack.include?(needle)
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  needle:    #{needle.inspect}"
    puts "  haystack:  #{haystack.inspect}"
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

# ============================================================
# JIT-2: HIR 構築 + ダンプ (SETSUNARUBY_DUMP_HIR=1 で有効化)
# ============================================================

# ---- ENV 未設定: HIR ダンプは出ず、hot 検出のみ ----
ENV.delete("SETSUNARUBY_DUMP_HIR")
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
assert_eq(out, "55\n",                                 "JIT-2 OFF: fib(10) 結果")
assert_eq(err, "ZJIT: hot method detected (idx=0)\n",  "JIT-2 OFF: HIR ダンプなし")

# ---- ENV=1: HIR ダンプが STDERR に出る ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
begin
  out, err = run_capture(fib_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
assert_eq(out, "55\n", "JIT-2 ON: fib(10) 結果は不変")
assert_includes(err, "ZJIT: hot method detected (idx=0)", "JIT-2 ON: hot 検出ログ")
assert_includes(err, "ZJIT HIR (raw) for method idx=0:",        "JIT-2 ON: HIR ヘッダ")
assert_includes(err, "LoadLocal slot=0",                  "JIT-2 ON: 引数 n の load")
assert_includes(err, "LoadConst 2",                       "JIT-2 ON: 定数 2")
assert_includes(err, "Lt ",                               "JIT-2 ON: < 比較")
assert_includes(err, "JumpIfFalse ",                      "JIT-2 ON: 条件分岐")
assert_includes(err, "Sub ",                              "JIT-2 ON: n - 1 / n - 2 の減算")
assert_includes(err, "Call m0(",                          "JIT-2 ON: 再帰呼び出し")
assert_includes(err, "Add ",                              "JIT-2 ON: fib(n-1) + fib(n-2)")
assert_includes(err, "Return ",                           "JIT-2 ON: 戻り命令")

# ---- 複数引数 (tarai 3 引数) でも CALL の引数列が dump される ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
tarai_src = <<~RUBY
  def tarai(x, y, z)
    if x <= y
      y
    else
      tarai(tarai(x - 1, y, z), tarai(y - 1, z, x), tarai(z - 1, x, y))
    end
  end
  puts tarai(6, 3, 0)
RUBY
begin
  out, err = run_capture(tarai_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
assert_eq(out, "6\n", "JIT-2 ON: tarai 結果は不変")
assert_includes(err, "ZJIT HIR (raw) for method idx=0:", "JIT-2 ON: tarai HIR ヘッダ")
assert_includes(err, "Le ",                        "JIT-2 ON: tarai の <= 比較")
# 3 引数 CALL は "Call m0(vA, vB, vC)" 形式
assert_includes(err, ", ",                         "JIT-2 ON: 引数区切り (多引数 CALL)")

# ---- 早期 return + 中間 if (jump target が POP/末尾境界を指すケース): patch アサート確認 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
abs_src = <<~RUBY
  def abs(n)
    if n < 0
      return -n
    end
    n
  end
  i = 0
  while i < 100
    abs(-7)
    i = i + 1
  end
  puts abs(-7)
RUBY
begin
  out, err = run_capture(abs_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
assert_eq(out, "7\n", "JIT-2 ON: abs(-7) 結果は不変")
assert_includes(err, "Pop",                          "JIT-2 ON: 早期 return パターンで POP HIR insn")
# v-1 という壊れた jump target が出ていないことを確認 (patch 未解決の検出)
broken = err.include?("v-1")
if !broken
  $pass += 1
  puts "ok   JIT-2 ON: 早期 return パターンで jump target が全て解決 (v-1 なし)"
else
  $fail += 1
  puts "FAIL JIT-2 ON: 早期 return パターンで未解決 jump target が残った"
  puts "  err: #{err.inspect}"
end

def assert_excludes(haystack, needle, label)
  if !haystack.include?(needle)
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  needle (should NOT appear): #{needle.inspect}"
    puts "  haystack: #{haystack.inspect}"
  end
end

# raw / optimized の 2 セクションだけを切り出す。
# index が見つからない場合でもテストハーネスを止めず、後続 assert に失敗させる。
def split_dump_sections(err)
  raw_idx = err.index("ZJIT HIR (raw)") || 0
  opt_idx = err.index("ZJIT HIR (optimized)") || err.length
  [err[raw_idx...opt_idx].to_s, err[opt_idx..-1].to_s]
end

# ============================================================
# JIT-3a: fold_constants + eliminate_dead_code (HIR 最適化)
# ============================================================

# ---- fold_constants: 整数算術 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fold_arith_src = <<~RUBY
  def f
    1 + 2 * 3
  end
RUBY
THRESHOLD.times { fold_arith_src << "f\n" }
fold_arith_src << "puts 0\n"
begin
  out, err = run_capture(fold_arith_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "0\n", "JIT-3a: 算術畳み込み 結果不変")
assert_includes(raw_section, "Add ",       "JIT-3a: raw に Add がある")
assert_includes(raw_section, "Mul ",       "JIT-3a: raw に Mul がある")
assert_excludes(opt_section, "Add ",       "JIT-3a: optimized で Add が畳み込み済み")
assert_excludes(opt_section, "Mul ",       "JIT-3a: optimized で Mul が畳み込み済み")
assert_includes(opt_section, "LoadConst 7", "JIT-3a: 1 + 2 * 3 = 7 に畳み込まれた")

# ---- fold_constants: 比較 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fold_cmp_src = <<~RUBY
  def g
    5 < 10
  end
RUBY
THRESHOLD.times { fold_cmp_src << "g\n" }
fold_cmp_src << "puts 0\n"
begin
  out, err = run_capture(fold_cmp_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "0\n", "JIT-3a: 比較畳み込み 結果不変")
assert_includes(raw_section, "Lt ",                 "JIT-3a: raw に Lt がある")
assert_excludes(opt_section, "Lt ",                 "JIT-3a: optimized で Lt が畳み込み済み")
assert_includes(opt_section, "LoadConst true",      "JIT-3a: 5 < 10 = true に畳み込まれた")

# ---- DIV by 0 は畳み込まない (raise を保つ) ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
div_zero_src = <<~RUBY
  def h(n)
    10 / n
  end
RUBY
THRESHOLD.times { div_zero_src << "h(2)\n" }
div_zero_src << "puts 0\n"
begin
  out, err = run_capture(div_zero_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
_raw, opt_section = split_dump_sections(err)
# n は LoadLocal なので畳み込めない (= Div は残る)
assert_includes(opt_section, "Div ",          "JIT-3a: 変数を含む Div は畳まれず残る")

# ---- 変数を含む式は畳まれない (fib の n は LoadLocal) ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_src_short = <<~RUBY
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end
  puts fib(10)
RUBY
begin
  out, err = run_capture(fib_src_short)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
_raw, opt_section = split_dump_sections(err)
assert_eq(out, "55\n", "JIT-3a: fib(10) 結果不変")
assert_includes(opt_section, "Lt ",  "JIT-3a: fib の Lt は LoadLocal を含むので残る")
assert_includes(opt_section, "Add ", "JIT-3a: fib(n-1) + fib(n-2) の Add は Call を含むので残る")
assert_includes(opt_section, "Sub ", "JIT-3a: n - 1 の Sub も残る")

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT-1/2/3a)"
exit($fail == 0 ? 0 : 1)
