$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/interp'
require 'stringio'

$pass = 0
$fail = 0

def run_with_interp(src)
  buf    = StringIO.new
  saved  = $stdout
  $stdout = buf
  interp = Setsunaruby::Interp.new
  begin
    interp.run_string(src)
  ensure
    $stdout = saved
  end
  [interp, buf.string]
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

def assert(cond, label)
  if cond
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label}"
  end
end

# ============================================================
# T1: 既存挙動の不変 (1024 未満の小規模実行で GC が起動しない)
# ============================================================

interp, out = run_with_interp(%(s = "hello"\nputs s\n))
assert_eq(out, "hello\n", "T1a: 短い実行は変わらず動作する")
assert_eq(interp.instance_variable_get(:@heap_freelist).length, 0,
          "T1b: 1024 未満の alloc では GC は起動しない (freelist 空)")

# ============================================================
# T2: 大量 String alloc で slot 数と freelist が想定通り推移する
# ============================================================

src = <<~'RUBY'
  i = 0
  while i < 5000
    s = "x" + "y"
    i = i + 1
  end
  puts s
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "xy\n", "T2a: 大量 alloc 後の最終 s は live で正しく出力される")
heap_len  = interp.instance_variable_get(:@heap_kind).length
free_len  = interp.instance_variable_get(:@heap_freelist).length
# heap.length は GC 後に freelist 経由で再利用されるため 1024 程度で頭打ちになる。
# slack を見て 1500 以下を期待 (理論上は 1024 ちょうど)。
assert(heap_len <= 1500, "T2b: heap_kind.length が頭打ち (len=#{heap_len})")
# freelist が活用された証拠 (= GC が起動した)。
assert(free_len > 0, "T2c: GC が起動して freelist が積まれる (free=#{free_len})")
# 強制 GC を 1 回追加で呼んで、本当のルート到達数を測る。
# 直前の GC 以降に freelist から再利用された slot は kind != TOMBSTONE のまま
# 残るので、`heap_len - free_len` は「tombstone でない slot 数」であって
# 「ルート到達可能 slot 数」ではない。両者を分離して観測する。
interp.send(:gc_collect)
real_live = heap_len - interp.instance_variable_get(:@heap_freelist).length
assert(real_live < 50, "T2d: 強制 GC 後の真の live は最終 s 周辺のみ (live=#{real_live})")

# ============================================================
# T3: 配列要素のルート保護 (mark が outer → inner を辿ること)
# ============================================================

src = <<~'RUBY'
  outer = [["a", "b"], ["c", "d"]]
  i = 0
  while i < 5000
    t = "x" + "y"
    i = i + 1
  end
  puts outer[0][0]
  puts outer[1][1]
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "a\nd\n", "T3: GC 中に outer から inner Array / 内部 String まで mark が連鎖する")

# ============================================================
# T4: instance ivar のルート保護
# ============================================================

src = <<~'RUBY'
  class Box
    def initialize(s)
      @s = s
    end
    def get
      @s
    end
  end
  b = Box.new("hello")
  i = 0
  while i < 5000
    t = "x" + "y"
    i = i + 1
  end
  puts b.get
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "hello\n", "T4: GC 中に instance の @s (ivar 経由) が mark で守られる")

# ============================================================
# T5: 例外オブジェクトのルート保護 (@exception)
# ============================================================

src = <<~'RUBY'
  begin
    raise "boom"
  rescue => e
    i = 0
    while i < 5000
      t = "x" + "y"
      i = i + 1
    end
    puts e.message
  end
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "boom\n", "T5: rescue 中の大量 alloc でも例外オブジェクトは GC されない")

# ============================================================
# T6: gc_collect 直接呼び出しの idempotency
# ============================================================

interp, _ = run_with_interp(%(puts "hi"\n))
# heap が空の状態でも GC が落ちないこと、複数回呼び出しても整合性が保たれること
3.times { interp.send(:gc_collect) }
$pass += 1
puts "ok   T6: gc_collect は終了後の任意のタイミングで安全に呼び出せる"

# ============================================================
# T7: Stage GC-2 - 文字列 << ループで @str_pool が頭打ち
# ============================================================

# `s << "x"` を繰り返すと relocate-and-grow で @str_pool 末尾に再配置され、
# 旧領域は abandon される。GC-2 圧縮なしだと @str_pool.length は 1+2+...+N ≒ N²/2 で
# 膨らむ。圧縮ありだと GC ごとに live byte だけが残り、最終的に s.length 程度に収まる。
src = <<~'RUBY'
  s = ""
  i = 0
  while i < 2000
    s << "x"
    i = i + 1
  end
  puts "done"
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "done\n", "T7a: 大量 << 後の完走 (String#length は未実装なので結果は内部状態で検査)")
# GC-2 なしなら ≒ 200万バイト。圧縮ありなら 2000 + α (現役 s + 直近の旧領域)。
# 強制 GC で「真の live byte」だけに絞る。
interp.send(:gc_collect)
str_pool_len = interp.instance_variable_get(:@str_pool).length
assert(str_pool_len < 3000,
       "T7b: 強制 GC 後の @str_pool.length が live (= 2000) 程度に圧縮される (str=#{str_pool_len})")

# ============================================================
# T8: Stage GC-2 - Array << ループで @heap_arr_pool が頭打ち
# ============================================================

src = <<~'RUBY'
  a = []
  i = 0
  while i < 2000
    a << i
    i = i + 1
  end
  puts a.length
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "2000\n", "T8a: 大量 << 後の最終 a.length")
interp.send(:gc_collect)
arr_pool_len = interp.instance_variable_get(:@heap_arr_pool).length
assert(arr_pool_len < 3000,
       "T8b: 強制 GC 後の @heap_arr_pool.length が live (= 2000) 程度に圧縮される (arr=#{arr_pool_len})")

# ============================================================
# T9: Stage GC-2 - 短命 instance の大量生成で @instance_ivar_pool が圧縮される
# ============================================================

src = <<~'RUBY'
  class Box
    def initialize(s)
      @s = s
    end
  end
  i = 0
  while i < 2000
    b = Box.new("hi")
    i = i + 1
  end
  puts "done"
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "done\n", "T9a: 大量 instance 生成後の完走")
interp.send(:gc_collect)
ivar_pool_len = interp.instance_variable_get(:@instance_ivar_pool).length
# 最終的に live な instance は b 1 個 (ivar 1 個)。
assert(ivar_pool_len < 50,
       "T9b: 強制 GC 後の @instance_ivar_pool.length が live instance 分のみ (ivar=#{ivar_pool_len})")

# ============================================================
# T10: Stage GC-2 - @strlit_pool は GC 対象外 (lex 確定の不変領域)
# ============================================================

src = <<~'RUBY'
  s = "hello"
  t = "world"
  puts s
  puts t
RUBY

interp, out = run_with_interp(src)
assert_eq(out, "hello\nworld\n", "T10a: literal を含むプログラムが正しく動作")
strlit_len_before = interp.instance_variable_get(:@strlit_pool).length
# literal "hello" + "world" = 10 バイトが少なくとも含まれる。
assert(strlit_len_before >= 10, "T10b: @strlit_pool に literal バイトが格納される (len=#{strlit_len_before})")
interp.send(:gc_collect)
strlit_len_after = interp.instance_variable_get(:@strlit_pool).length
assert_eq(strlit_len_after, strlit_len_before, "T10c: GC で @strlit_pool は変化しない (literal は不変領域)")

# ============================================================
# サマリ
# ============================================================
puts ""
puts "GC tests: #{$pass} passed, #{$fail} failed"
exit($fail == 0 ? 0 : 1)
