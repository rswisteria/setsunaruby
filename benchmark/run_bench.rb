# CRuby 版 (ruby bin/setsunaruby.rb) と AOT 版 (./setsunaruby) を
# benchmark/bench*.rb で実行して中央値で比較するスクリプト。
#
# 事前に AOT バイナリを用意してから実行:
#   make build && ruby benchmark/run_bench.rb
# または
#   make bench

require 'open3'

BENCHMARKS = Dir["benchmark/bench*.rb"].sort
RUNS       = 5
AOT_BIN    = './setsunaruby'

unless File.executable?(AOT_BIN)
  STDERR.puts "AOT binary not found at #{AOT_BIN}. Run: make build"
  exit 1
end

def time_ms(cmd, args)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, _err, _status = Open3.capture3(cmd, *args)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [((t1 - t0) * 1000).round(1), out]
end

def median(arr)
  s = arr.sort
  n = s.length
  n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
end

puts "ベンチマーク (#{RUNS}回計測の中央値、単位: ms)"
puts "=" * 80
printf "%-26s %10s %10s %10s\n", "name", "CRuby", "AOT", "speedup"
puts "-" * 80

BENCHMARKS.each do |f|
  c_times = []
  a_times = []
  c_out = nil
  a_out = nil
  RUNS.times do
    ct, c_out = time_ms('ruby', ['bin/setsunaruby.rb', f])
    at, a_out = time_ms(AOT_BIN, [f])
    c_times << ct
    a_times << at
  end
  if c_out != a_out
    STDERR.puts "WARNING: output mismatch on #{f}"
  end
  c_med = median(c_times)
  a_med = median(a_times)
  speedup = (c_med / a_med).round(2)
  printf "%-26s %10.1f %10.1f %9.2fx\n",
         File.basename(f, ".rb"), c_med, a_med, speedup
end

puts "=" * 80
