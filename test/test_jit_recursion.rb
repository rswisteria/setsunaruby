# JIT-4c regalloc: 再帰と multi-BB を含むメソッドの実機実行テスト。
# 線形 scan + spill + label fixup + 自己再帰 BL を組み合わせた end-to-end 検証。
#
# 前提: `make build SPINEL=... SPINEL_HOME=...` で AOT バイナリが作成済み。
# arm64 環境でのみ実機実行される (x86_64 ホストは multi-BB を install しない)。

require 'tempfile'
require 'open3'

AOT_BIN = File.expand_path('../setsunaruby', __dir__)
unless File.executable?(AOT_BIN)
  STDERR.puts "AOT binary not found: #{AOT_BIN}"
  STDERR.puts "Run: make build"
  exit 1
end

CRUBY_BIN = File.expand_path('../bin/setsunaruby.rb', __dir__)

$pass = 0
$fail = 0

def jit_aot_run(src)
  Tempfile.create(['jit_rec', '.rb']) do |f|
    f.write(src)
    f.close
    out, _err, _status = Open3.capture3({ 'SETSUNARUBY_JIT' => '1' }, AOT_BIN, f.path)
    out
  end
end

def cruby_run(src)
  Tempfile.create(['jit_rec_cruby', '.rb']) do |f|
    f.write(src)
    f.close
    out, _err, _status = Open3.capture3('ruby', CRUBY_BIN, f.path)
    out
  end
end

def assert_jit_matches_cruby(src, label)
  jit_out   = jit_aot_run(src)
  cruby_out = cruby_run(src)
  if jit_out == cruby_out
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
    puts "  JIT:   #{jit_out.inspect}"
    puts "  CRuby: #{cruby_out.inspect}"
  end
end

# --- fib 完走 (明示的 local 経由) ---
# 自己再帰 BL + multi-BB (if/else) + linear-scan reg alloc + spill が全部協調する
# end-to-end ケース。明示的に result = ... の形にすることで HIR の phi が正しく
# 挿入され、JIT install 経路に乗る。
assert_jit_matches_cruby(<<~RUBY, "fib(10) を JIT 経由で実行")
  def fib(n)
    result = 0
    if n < 2
      result = n
    else
      result = fib(n - 1) + fib(n - 2)
    end
    result
  end
  i = 0
  while i < 105
    fib(5)
    i = i + 1
  end
  puts fib(10)
RUBY

# --- if-expression 形式の fib は install 拒否される ---
# HIR の Return が phi を経由せず BB2 の値だけを参照する既存バグを持つため、
# install_jit_for_method が dominance チェックで install 拒否し、bytecode 経路に
# フォールバックする。
assert_jit_matches_cruby(<<~RUBY, "fib(10) (if-expression 形式) は bytecode fallback で正解")
  def fib(n)
    if n < 2
      n
    else
      fib(n - 1) + fib(n - 2)
    end
  end
  i = 0
  while i < 105
    fib(5)
    i = i + 1
  end
  puts fib(10)
RUBY

# --- ループ + 再帰なし: linear-scan + spill のみ ---
assert_jit_matches_cruby(<<~RUBY, "ループのみ (count_up) を JIT 経由で実行")
  def count_up(n)
    i = 0
    while i < n
      i = i + 1
    end
    i
  end
  k = 0
  r = 0
  while k < 105
    r = count_up(10)
    k = k + 1
  end
  puts r
RUBY

# --- 引数 3 個の sum3 (BL なし、レジスタ割当のみ) ---
assert_jit_matches_cruby(<<~RUBY, "sum3(a,b,c) を JIT 経由で実行")
  def sum3(a, b, c)
    a + b + c
  end
  i = 0
  r = 0
  while i < 105
    r = sum3(1, 2, 3)
    i = i + 1
  end
  puts r
RUBY

# --- 引数なし: callee-saved 不要、frame size 16 のみ ---
assert_jit_matches_cruby(<<~RUBY, "0 引数メソッドを JIT 経由で実行")
  def const_42
    42
  end
  i = 0
  r = 0
  while i < 105
    r = const_42
    i = i + 1
  end
  puts r
RUBY

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT recursion / multi-BB)"
exit($fail == 0 ? 0 : 1)
