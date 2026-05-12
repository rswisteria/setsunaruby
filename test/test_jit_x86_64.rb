# JIT-4c x86_64 (System V AMD64) エンコーダのバイト列単体テスト。CRuby 上で実行する。
#
# `pass_encode_x86_64` を強制的に走らせて @jit_bytes が期待値と一致することだけ確認する
# (= encode の正しさのみ検証、実機実行は x86_64 Linux 環境で別途確認)。
#
# 検証戦略: `Interp.new` で初期化 → `JIT` モジュールが defined? のとき
# `ARCH_ARM64 == false` の x86_64 経路を選ぶので、ここでは Interp 内部の
# `pass_encode_native` をモンキーパッチして強制的に `pass_encode_x86_64` を呼ぶ。
# JIT モジュールは CRuby に無いので install には進まない。

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/interp'
require 'stringio'
require 'tempfile'

$pass = 0
$fail = 0

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

# x86_64 経路を強制する Interp サブクラス。CRuby 上で run_string した結果 @jit_bytes に
# 機械語バイト列が入る。
class X86Interp < Setsunaruby::Interp
  def pass_encode_native
    pass_encode_x86_64
  end
end

# 与えた src で `@jit_bytes` を作って返す。
# CRuby では `defined?(JIT)` が nil なので `jit_install_viable?` が false になり、
# build_and_dump_hir を発火させるには `@dump_hir = true` が必要。`@dump_hir` は
# run_string 冒頭で ENV から再読み込みされるため、ENV 経由でセットする。
# 結果として HIR/LIR ダンプが STDERR に出るので tempfile に逃がす。
def encode_x86_64_for(src)
  saved_stderr = STDERR.dup
  err_tmp = Tempfile.new('jit_x64_stderr')
  STDERR.reopen(err_tmp.path, 'w')
  saved_env = ENV['SETSUNARUBY_DUMP_HIR']
  ENV['SETSUNARUBY_DUMP_HIR'] = '1'
  interp = nil
  begin
    interp = X86Interp.new
    interp.run_string(src)
  ensure
    ENV['SETSUNARUBY_DUMP_HIR'] = saved_env
    STDERR.flush
    STDERR.reopen(saved_stderr)
    saved_stderr.close
    err_tmp.close!
  end
  interp.instance_variable_get(:@jit_bytes)
end

# --- 恒等関数 def id(n); n; end のエンコード ---
# 新 allocator により LoadParam(0) は vreg 19 = RBX に割当てられる。saved_reg_count=1
# のため FRAME_ENTER は push rbp + mov rbp,rsp + sub rsp,#32 + save rbx を生成し、
# FRAME_LEAVE で逆順に restore + add rsp + pop rbp。MOV_FROM_ARG = mov rbx, rdi、
# MOV_TO_RET = mov rax, rbx。
src_id = <<~RUBY
  def id(n)
    n
  end
  i = 0
  while i < 105
    id(i)
    i = i + 1
  end
RUBY

bytes = encode_x86_64_for(src_id)
expected = [
  # FRAME_ENTER #32
  0x55,                                    # push rbp
  0x48, 0x89, 0xE5,                        # mov rbp, rsp
  0x48, 0x81, 0xEC, 0x20, 0x00, 0x00, 0x00, # sub rsp, #32
  0x48, 0x89, 0x9D, 0xF8, 0xFF, 0xFF, 0xFF, # mov [rbp-8], rbx (save callee-saved)
  # body
  0x48, 0x89, 0xFB,                        # mov rbx, rdi (= LoadParam slot 0)
  0x48, 0x89, 0xD8,                        # mov rax, rbx (= return value)
  # FRAME_LEAVE #32
  0x48, 0x8B, 0x9D, 0xF8, 0xFF, 0xFF, 0xFF, # mov rbx, [rbp-8] (restore)
  0x48, 0x81, 0xC4, 0x20, 0x00, 0x00, 0x00, # add rsp, #32
  0x5D,                                    # pop rbp
  # RET
  0xC3
]
assert_eq(bytes, expected, "id(n) を x86_64 にエンコード (新 allocator)")

# --- add(a, b) = a + b ---
# LIR: FRAME_ENTER + MOV_FROM_ARG x19/x20 + ADD/SUB_IMM (boxing 補正) + MOV_TO_RET +
#      FRAME_LEAVE + RET。CRuby tests では GUARD_FIXNUM が残るため末尾に NOP プレースホルダ。
# 物理マッピング: vreg 19=rbx, 20=r12, 22=r13。
src_add = <<~RUBY
  def add(a, b)
    a + b
  end
  i = 0
  r = 0
  while i < 105
    r = add(i, 1)
    i = i + 1
  end
RUBY

bytes_add = encode_x86_64_for(src_add)
expected_add = [
  # FRAME_ENTER #48 (saved_reg_count=3、callee-saved を rbx/r12/r13 まで保存)
  0x55,
  0x48, 0x89, 0xE5,
  0x48, 0x81, 0xEC, 0x30, 0x00, 0x00, 0x00,
  0x48, 0x89, 0x9D, 0xF8, 0xFF, 0xFF, 0xFF, # mov [rbp-8], rbx
  0x4C, 0x89, 0xA5, 0xF0, 0xFF, 0xFF, 0xFF, # mov [rbp-16], r12
  0x4C, 0x89, 0xAD, 0xE8, 0xFF, 0xFF, 0xFF, # mov [rbp-24], r13
  # body
  0x48, 0x89, 0xFB,                         # mov rbx, rdi (param a → vreg 19)
  0x49, 0x89, 0xF4,                         # mov r12, rsi (param b → vreg 20)
  0x49, 0x89, 0xDD,                         # mov r13, rbx (dst = lhs, prep ADD)
  0x4D, 0x01, 0xE5,                         # add r13, r12
  0x49, 0x81, 0xED, 0x01, 0x00, 0x00, 0x00, # sub r13, #1 (boxing -1 補正)
  0x4C, 0x89, 0xE8,                         # mov rax, r13 (return)
  # FRAME_LEAVE #48
  0x48, 0x8B, 0x9D, 0xF8, 0xFF, 0xFF, 0xFF,
  0x4C, 0x8B, 0xA5, 0xF0, 0xFF, 0xFF, 0xFF,
  0x4C, 0x8B, 0xAD, 0xE8, 0xFF, 0xFF, 0xFF,
  0x48, 0x81, 0xC4, 0x30, 0x00, 0x00, 0x00,
  0x5D,
  # RET
  0xC3,
  # GUARD_FIXNUM の TBZ プレースホルダ (x19, x20、各 6 byte NOP)
  0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
  0x90, 0x90, 0x90, 0x90, 0x90, 0x90
]
assert_eq(bytes_add, expected_add, "add(a, b) を x86_64 にエンコード (新 allocator + 2-operand)")

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT x86_64 encoder unit)"
exit($fail == 0 ? 0 : 1)
