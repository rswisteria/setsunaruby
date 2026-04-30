require_relative '../lib/setsunaruby/interp'

# spinel がトップレベルローカル変数に volatile 修飾を付けて型不整合を
# 引き起こすため、コア処理は run 関数にまとめてスコープを閉じる。
# ARGV は spinel の制約で関数内で使えないのでトップレベルで取得する。
def run(path)
  Setsunaruby::Interp.new.run_file(path)
end

if ARGV.length != 1
  STDERR.puts "usage: setsunaruby <file.rb>"
  exit 1
end

run(ARGV[0])
