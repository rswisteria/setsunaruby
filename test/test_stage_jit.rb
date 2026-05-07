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
expected_log = "ZJIT: hot method detected (idx=6)\n"   # Stage 3d.3: idx=0 は builtin Array#length が占有
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
assert_eq(err, expected_log, "fib(10) で fib (idx=6) が hot 検出")

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
expected_multi = "ZJIT: hot method detected (idx=6)\nZJIT: hot method detected (idx=7)\n"   # Stage 3d.3: builtin Array#length が idx=0 を占有
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
assert_eq(err, "ZJIT: hot method detected (idx=6)\n",  "JIT-2 OFF: HIR ダンプなし (Stage 3d.3 で idx=6)")

# ---- ENV=1: HIR ダンプが STDERR に出る ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
begin
  out, err = run_capture(fib_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
assert_eq(out, "55\n", "JIT-2 ON: fib(10) 結果は不変")
assert_includes(err, "ZJIT: hot method detected (idx=6)", "JIT-2 ON: hot 検出ログ")
assert_includes(err, "ZJIT HIR (raw) for method idx=6:",        "JIT-2 ON: HIR ヘッダ")
assert_includes(err, "LoadLocal slot=0",                  "JIT-2 ON: 引数 n の load")
assert_includes(err, "LoadConst 2",                       "JIT-2 ON: 定数 2")
assert_includes(err, "Lt ",                               "JIT-2 ON: < 比較")
assert_includes(err, "JumpIfFalse ",                      "JIT-2 ON: 条件分岐")
assert_includes(err, "Sub ",                              "JIT-2 ON: n - 1 / n - 2 の減算")
assert_includes(err, "Call m6(",                          "JIT-2 ON: 再帰呼び出し (Stage 3d.3 で fib は m1)")
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
assert_includes(err, "ZJIT HIR (raw) for method idx=6:", "JIT-2 ON: tarai HIR ヘッダ")
assert_includes(err, "Le ",                        "JIT-2 ON: tarai の <= 比較")
# 3 引数 CALL は "Call m5(vA, vB, vC)" 形式
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

# ============================================================
# JIT-3b1: basic block + CFG + clean_cfg
# ============================================================

# ---- fib の HIR が BB 単位でダンプされる ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_bb_src = <<~RUBY
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
  out, err = run_capture(fib_bb_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "55\n", "JIT-3b1: fib(10) 結果不変")
assert_includes(raw_section, "BB0:",                  "JIT-3b1: BB0 が出る")
assert_includes(raw_section, "BB1 (preds: BB0)",      "JIT-3b1: BB1 の preds 表示")
assert_includes(raw_section, "BB3 (preds: BB1, BB2)", "JIT-3b1: BB3 の合流点 preds")
assert_includes(raw_section, ", BB2",                 "JIT-3b1: Jump target が BB 表記")
assert_includes(raw_section, "Jump BB3",              "JIT-3b1: Jump も BB 表記")

# ---- 早期 return パターン: unreachable BB が clean_cfg で削除される ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
abs_clean_src = <<~RUBY
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
  out, err = run_capture(abs_clean_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "7\n", "JIT-3b1: abs(-7) 結果不変")
# raw では unreachable BB (早期 return 直後の死コード) が存在する
assert_includes(raw_section, "BB2:",  "JIT-3b1: raw では BB2 (unreachable) が出る")
# optimized では unreachable BB が消えている
assert_excludes(opt_section, "BB2:",  "JIT-3b1: optimized で unreachable BB が clean されている")
# 合流先の preds リストも更新されている (BB2 が消えるので merge BB の preds は BB3 のみ)
assert_includes(opt_section, "(preds: BB3)", "JIT-3b1: clean 後 merge BB の preds が更新")

# ============================================================
# JIT-3b2: dominator tree + dominance frontier
# ============================================================

def split_cfg_section(err)
  marker = "ZJIT CFG analysis"
  idx = err.index(marker) || err.length
  err[idx..-1].to_s
end

# ---- fib の dominator + DF ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_dom_src = <<~RUBY
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
  out, err = run_capture(fib_dom_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
cfg_section = split_cfg_section(err)
assert_eq(out, "55\n", "JIT-3b2: fib(10) 結果不変")
assert_includes(cfg_section, "ZJIT CFG analysis for method idx=6:", "JIT-3b2: 分析ヘッダ")
# fib は entry → (then|else) → merge の標準 diamond CFG
assert_includes(cfg_section, "BB0: idom=BB0, DF={}",     "JIT-3b2: entry の idom は自分、DF 空")
assert_includes(cfg_section, "BB1: idom=BB0, DF={BB3}",  "JIT-3b2: then 節の DF は merge")
assert_includes(cfg_section, "BB2: idom=BB0, DF={BB3}",  "JIT-3b2: else 節の DF は merge")
assert_includes(cfg_section, "BB3: idom=BB0, DF={}",     "JIT-3b2: merge BB の idom は entry")

# ---- 単純メソッド (1 BB のみ): idom=自分、DF 空 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
simple_src = <<~RUBY
  def f(n)
    n + 1
  end
RUBY
THRESHOLD.times { simple_src << "f(2)\n" }
simple_src << "puts 0\n"
begin
  out, err = run_capture(simple_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
cfg_section = split_cfg_section(err)
assert_eq(out, "0\n",                            "JIT-3b2: 単純メソッド 結果不変")
assert_includes(cfg_section, "BB0: idom=BB0, DF={}", "JIT-3b2: 単一 BB は idom=自分 DF 空")
# 1 BB しかないので BB1 以降は出ない
assert_excludes(cfg_section, "BB1:",                 "JIT-3b2: 1 BB のみ、BB1 以降は出ない")

# ---- 早期 return + 中間 if (unreachable BB は分析からスキップ) ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
abs_dom_src = <<~RUBY
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
  out, err = run_capture(abs_dom_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
cfg_section = split_cfg_section(err)
assert_eq(out, "7\n", "JIT-3b2: abs(-7) 結果不変")
# unreachable BB2 は alive_count=0 でスキップされる
assert_excludes(cfg_section, "BB2:", "JIT-3b2: unreachable BB は CFG 分析でスキップ")

# ============================================================
# JIT-3b3: phi 挿入 + variable renaming (本格 SSA 化)
# ============================================================

# ---- パラメータが LoadParam として BB0 先頭に並ぶ ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_ssa_src = <<~RUBY
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
  out, err = run_capture(fib_ssa_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "55\n", "JIT-3b3: fib(10) 結果不変")
assert_includes(raw_section, "v0 = LoadParam slot=0", "JIT-3b3: BB0 先頭に LoadParam が emit される")
# rename 後は LOAD_LOCAL が消えて LoadParam を直接参照
assert_excludes(opt_section, "LoadLocal", "JIT-3b3: optimized で LoadLocal が消える")
# fib では n は再代入されないので phi は不要
assert_excludes(opt_section, "Phi ", "JIT-3b3: 単一 def の slot は phi 不要")

# ---- if-else で同じ slot を再代入 → 合流点に phi 挿入 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
phi_src = <<~RUBY
  def choose(c)
    if c
      x = 100
    else
      x = 200
    end
    x
  end
RUBY
THRESHOLD.times { phi_src << "choose(true)\n" }
phi_src << "puts choose(true)\nputs choose(false)\n"
begin
  out, err = run_capture(phi_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "100\n200\n", "JIT-3b3: choose の結果が phi 後も保たれる")
# raw では LoadLocal/StoreLocal が両方ある
assert_includes(raw_section, "StoreLocal slot=1", "JIT-3b3: raw に StoreLocal がある")
assert_includes(raw_section, "LoadLocal slot=1",  "JIT-3b3: raw に LoadLocal がある")
# optimized では phi が挿入されて LOAD/STORE_LOCAL は消える
assert_includes(opt_section, "Phi slot=1",  "JIT-3b3: 合流点に phi 挿入")
assert_includes(opt_section, "BB1 -> v",    "JIT-3b3: phi の BB1 経由の値が記録")
assert_includes(opt_section, "BB2 -> v",    "JIT-3b3: phi の BB2 経由の値が記録")
assert_excludes(opt_section, "StoreLocal",  "JIT-3b3: optimized で StoreLocal が消える")
assert_excludes(opt_section, "LoadLocal",   "JIT-3b3: optimized で LoadLocal が消える")
# Return が phi の hir_id を参照するように rename される
assert_includes(opt_section, "Return ",     "JIT-3b3: Return は残る")

# ---- while ループ: loop header に phi 挿入 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
loop_src = <<~RUBY
  def sum_to(n)
    i = 0
    s = 0
    while i < n
      s = s + i
      i = i + 1
    end
    s
  end
RUBY
THRESHOLD.times { loop_src << "sum_to(5)\n" }
loop_src << "puts sum_to(10)\n"
begin
  out, err = run_capture(loop_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
_raw, opt_section = split_dump_sections(err)
assert_eq(out, "45\n", "JIT-3b3: sum_to(10) = 45 (loop 結果不変)")
# while ループでは i と s が loop header BB で再代入される → phi 挿入
assert_includes(opt_section, "Phi ", "JIT-3b3: while ループで phi 挿入")
assert_excludes(opt_section, "StoreLocal", "JIT-3b3: while ループでも StoreLocal が消える")

# ============================================================
# JIT-3c: 型プロファイル + GuardFixnum + Fixnum 特化
# ============================================================

# ---- fib で算術/比較が Fixnum 特化される ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_typespec_src = <<~RUBY
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
  out, err = run_capture(fib_typespec_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
raw_section, opt_section = split_dump_sections(err)
assert_eq(out, "55\n", "JIT-3c: fib(10) 結果不変")
# raw では generic Lt/Sub/Add
assert_includes(raw_section, "Lt v",  "JIT-3c: raw に generic Lt")
assert_includes(raw_section, "Sub v", "JIT-3c: raw に generic Sub")
assert_includes(raw_section, "Add v", "JIT-3c: raw に generic Add")
# optimized では FixnumLt/FixnumSub/FixnumAdd に特化
assert_includes(opt_section, "FixnumLt ",  "JIT-3c: optimized で Lt → FixnumLt")
assert_includes(opt_section, "FixnumSub ", "JIT-3c: optimized で Sub → FixnumSub")
assert_includes(opt_section, "FixnumAdd ", "JIT-3c: optimized で Add → FixnumAdd")
# GuardFixnum が各オペランドに挿入される
assert_includes(opt_section, "GuardFixnum ", "JIT-3c: GuardFixnum が挿入される")

# ---- 観測されない算術は特化されない (= プロファイル収集が機能) ----
# 観測されない opcode を作るには、ホット検出前のメソッドで実行されない
# arith があれば良い。実用的にはメソッド本体内で常に実行されるので、
# 別の方法: 実行されないと観測フラグが立たない → 分岐の片側でしか実行されない
# 算術を持つメソッドを作る。choose(true) を 100 回呼ぶと else 側 (x = 200) は
# 一度も実行されないが、x の代入自体には算術がない。fib の場合は全 arith が
# 必ず実行される。検証は fib の特化済みケースで十分。

# ---- choose で if-else 各分岐の合流に GuardFixnum/Phi/特化が共存 ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
arith_phi_src = <<~RUBY
  def add_or_sub(c, a, b)
    if c
      r = a + b
    else
      r = a - b
    end
    r
  end
RUBY
THRESHOLD.times { arith_phi_src << "add_or_sub(true, 7, 3)\n" }
arith_phi_src << "puts add_or_sub(true, 10, 4)\nputs add_or_sub(false, 10, 4)\n"
begin
  out, err = run_capture(arith_phi_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
_raw, opt_section = split_dump_sections(err)
assert_eq(out, "14\n6\n", "JIT-3c: 結果不変")
# c が真側 (a + b) しか実行されない場合、a - b の Sub は Fixnum 特化されない
# (= profile_fixnum_pc が立っていない)。else 側を一度でも通すと特化される。
# ホット検出の閾値到達時点で c=true 側のみ実行されているので、Sub は generic のまま
assert_includes(opt_section, "FixnumAdd ", "JIT-3c: 観測された Add は特化される")
# Sub は観測されていないので generic のまま
assert_includes(opt_section, "Sub ",       "JIT-3c: 観測されない Sub は generic のまま残る")
assert_excludes(opt_section, "FixnumSub ", "JIT-3c: 観測されない Sub は FixnumSub にならない")

# ============================================================
# JIT-4 (案 A): HIR → LIR lowering + arm64 エンコーダ + ダンプ
# ============================================================

def split_lir_section(err)
  marker = "ZJIT LIR for method"
  idx = err.index(marker) || err.length
  err[idx..-1].to_s
end

# ---- fib で LIR ダンプが出る ----
ENV["SETSUNARUBY_DUMP_HIR"] = "1"
fib_lir_src = <<~RUBY
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
  out, err = run_capture(fib_lir_src)
ensure
  ENV.delete("SETSUNARUBY_DUMP_HIR")
end
lir = split_lir_section(err)
assert_eq(out, "55\n", "JIT-4: fib(10) 結果不変")
assert_includes(lir, "ZJIT LIR for method idx=6:", "JIT-4: LIR ヘッダ")
# arm64 主要命令が出る
assert_includes(lir, "mov x",      "JIT-4: mov 命令")
assert_includes(lir, "sub x",      "JIT-4: sub 命令")
assert_includes(lir, "add x",      "JIT-4: add 命令")
assert_includes(lir, "cmp x",      "JIT-4: cmp 命令")
assert_includes(lir, "b.ge BB",    "JIT-4: FixnumLt の偽分岐は B_GE")
assert_includes(lir, "b BB",       "JIT-4: 無条件 jump")
assert_includes(lir, "bl m6",      "JIT-4: 再帰呼び出し (Stage 3d.3 で fib は m1)")
assert_includes(lir, "ret",        "JIT-4: return")
assert_includes(lir, "tbz x",      "JIT-4: GuardFixnum (TBZ)")
# 機械語 hex が併記される
assert_includes(lir, "    ; 0x",   "JIT-4: 機械語 hex 表示")
# RET の機械語は固定 0xd65f03c0
assert_includes(lir, "0xd65f03c0", "JIT-4: ret の正しい機械語")
# ADD register 命令の上位 8 ビットは 0x8b
assert_includes(lir, "    ; 0x8b", "JIT-4: add reg の 0x8b プレフィクス")

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT-1/2/3a/3b1/3b2/3b3/3c/4)"
exit($fail == 0 ? 0 : 1)
