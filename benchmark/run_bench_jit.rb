# JIT 有無の性能比較ベンチマーク。
# benchmark/bench_jit_*.rb を CRuby / AOT (no JIT) / AOT + SETSUNARUBY_JIT=1 の
# 3 系統で実行し、中央値で比較する。
#
# 事前: `make build SPINEL=... SPINEL_HOME=...` (= 個人 fork の spinel が必要)。
# `make bench-jit` から呼ばれる。
#
# 出力:
#   1) ASCII 表 (端末向け、整列出力)
#   2) Markdown 表 (README 等への貼り付け用、末尾に出力)

require 'open3'

BENCHMARKS = Dir["benchmark/bench_jit_*.rb"].sort
RUNS       = 5
AOT_BIN    = './setsunaruby'

unless File.executable?(AOT_BIN)
  STDERR.puts "AOT binary not found at #{AOT_BIN}. Run: make build"
  exit 1
end

def time_ms(env, cmd, args)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, _err, _status = Open3.capture3(env, cmd, *args)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [((t1 - t0) * 1000).round(1), out]
end

def median(arr)
  s = arr.sort
  n = s.length
  n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
end

rows = []

puts "JIT パフォーマンス比較 (#{RUNS} 回計測の中央値、単位: ms)"
puts "=" * 90
printf "%-26s %12s %12s %12s %12s\n",
       "name", "CRuby", "AOT (no JIT)", "AOT + JIT", "JIT speedup"
puts "-" * 90

BENCHMARKS.each do |f|
  c_times = []
  a_times = []
  j_times = []
  c_out = nil
  a_out = nil
  j_out = nil
  RUNS.times do
    ct, c_out = time_ms({}, 'ruby', ['bin/setsunaruby.rb', f])
    at, a_out = time_ms({}, AOT_BIN, [f])
    jt, j_out = time_ms({ 'SETSUNARUBY_JIT' => '1' }, AOT_BIN, [f])
    c_times << ct
    a_times << at
    j_times << jt
  end
  if c_out != a_out || a_out != j_out
    STDERR.puts "WARNING: output mismatch on #{f}"
    STDERR.puts "  CRuby: #{c_out.inspect[0..120]}"
    STDERR.puts "  AOT:   #{a_out.inspect[0..120]}"
    STDERR.puts "  JIT:   #{j_out.inspect[0..120]}"
  end
  c_med = median(c_times)
  a_med = median(a_times)
  j_med = median(j_times)
  jit_speedup = a_med / j_med
  printf "%-26s %12.1f %12.1f %12.1f %11.2fx\n",
         File.basename(f, ".rb"), c_med, a_med, j_med, jit_speedup
  rows << [File.basename(f, ".rb"), c_med, a_med, j_med, jit_speedup]
end

puts "=" * 90
puts ""
puts "JIT speedup = (AOT no-JIT 中央値) / (AOT+JIT 中央値)"
puts "1.00x 近辺 = JIT 化されていない / 効果なし、> 1.0x = JIT が機械語直行で高速化"
puts ""
puts "--- Markdown 表 (README 用) ---"
puts ""
puts "| benchmark | CRuby (ms) | AOT no-JIT (ms) | AOT + JIT (ms) | JIT speedup |"
puts "|---|---:|---:|---:|---:|"
rows.each do |name, c, a, j, sp|
  printf "| %s | %.1f | %.1f | %.1f | %.2fx |\n", name, c, a, j, sp
end
