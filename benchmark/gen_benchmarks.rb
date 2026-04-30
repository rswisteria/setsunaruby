# benchmark/bench*.rb の入力を再生成するスクリプト。
# Stage 0 の機能 (puts + 算術 + 比較 + 単項マイナス + 括弧) のみ使用。
# 結果が決定的になるよう srand で seed を固定する。

srand(42)

LINES = 2000

File.write("benchmark/bench1_many_puts.rb",
  LINES.times.map { "puts #{rand(100)}" }.join("\n") + "\n")

File.write("benchmark/bench2_deep_arith.rb",
  LINES.times.map {
    expr = (1..20).map { rand(1..9) }.join(" + ")
    "puts #{expr}"
  }.join("\n") + "\n")

File.write("benchmark/bench3_large_int.rb",
  LINES.times.map { "puts #{rand(1_000_000_000)}" }.join("\n") + "\n")

File.write("benchmark/bench4_compare.rb",
  LINES.times.map {
    a = rand(100); b = rand(100)
    op = ['==', '<', '>', '<=', '>='].sample
    "puts #{a} #{op} #{b}"
  }.join("\n") + "\n")

File.write("benchmark/bench5_mixed.rb",
  LINES.times.map {
    "puts -(#{rand(1..50)} + #{rand(1..50)}) * #{rand(2..9)}"
  }.join("\n") + "\n")

puts "Generated 5 benchmark files (2000 lines each)"
