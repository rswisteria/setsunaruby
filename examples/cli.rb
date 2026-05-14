# Stage 4f: 標準ライブラリ最低限 (File.read / ARGV / STDERR / exit)。
# CLI 風のスクリプトで全 4 機能を使う。
#
# AOT バイナリ起動 (`./setsunaruby examples/cli.rb`) では bin/setsunaruby.rb が
# 追加引数を setsunaruby ARGV にブリッジしないため、ARGV は常に空。CRuby
# (`ruby bin/setsunaruby.rb examples/cli.rb`) でも同様 (= path 引数のみサポート)。
# ARGV を実際に使うには test/test_stage4f.rb のように埋め込み利用で
# Interp#prepare_for_run + internal helper 経由で構築する。

# ARGV が空でも下流が落ちないように分岐する。
if ARGV.length == 0
  STDERR.puts("no arguments — using default")
  # 任意ファイルを読み込む例として examples/hello.rb を使う。
  contents = File.read("examples/hello.rb")
  puts contents
  exit 0
end

# ARGV が 1 つ以上ある場合は最初の引数をファイルパスとして read する。
target = ARGV[0]
puts "reading: " + target
puts File.read(target)

# 終了 status を ARGV.length に揃える (デモ用)。
exit ARGV.length
