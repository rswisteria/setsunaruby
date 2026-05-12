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
# LIR: MOV_FROM_ARG x9, arg0 ; MOV_TO_RET x9 ; RET
#
#   MOV_FROM_ARG dst=9 (= r8), slot=0 (= rdi)
#     mov r/m64, r64 で dst=r8 (r/m), src=rdi (reg)
#     REX.W=1 + REX.B=1 (r8>=8) + REX.R=0 (rdi<8) → 0x49
#     opcode 0x89, ModRM 0xC0 | ((7 & 7) << 3) | (8 & 7) = 0xF8
#     bytes: 49 89 F8
#   MOV_TO_RET src=9 (= r8): mov rax, r8
#     REX.W + REX.R=1 (r8>=8) + REX.B=0 (rax<8) → 0x4C
#     opcode 0x89, ModRM 0xC0 | ((8 & 7) << 3) | (0 & 7) = 0xC0
#     bytes: 4C 89 C0
#   RET → C3
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
  0x49, 0x89, 0xF8,                # mov r8, rdi
  0x4C, 0x89, 0xC0,                # mov rax, r8
  0xC3                              # ret
]
assert_eq(bytes, expected, "id(n) を x86_64 にエンコード")

# --- add(a, b) = a + b ---
# LIR (型プロファイル経由で FIXNUM_ADD に specialize される想定):
#   MOV_FROM_ARG dst=9 (r8), slot=0 (rdi)
#   MOV_FROM_ARG dst=10 (r9), slot=1 (rsi)
#   ADD dst=13 (r12), lhs=9 (r8), rhs=10 (r9)   # 2-operand: mov r12, r8 ; add r12, r9
#   MOV_TO_RET src=13 (r12)
#   RET
#   TBZ x9 / TBZ x10                             # GUARD_FIXNUM (BB 末尾に emit)
#
# TBZ は x86_64 では test+jz 相当の実装に変える必要があるが、現状は multi-BB / call
# と一緒に install 側で弾く前提なので 6 byte NOP プレースホルダで埋めている。
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
  0x49, 0x89, 0xF8,                # mov r8, rdi
  0x49, 0x89, 0xF1,                # mov r9, rsi
  0x4D, 0x89, 0xC4,                # mov r12, r8
  0x4D, 0x01, 0xCC,                # add r12, r9
  0x4C, 0x89, 0xE0,                # mov rax, r12
  0xC3,                            # ret
  # GUARD_FIXNUM x9 / x10 の TBZ プレースホルダ (各 6 byte NOP)
  0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
  0x90, 0x90, 0x90, 0x90, 0x90, 0x90
]
assert_eq(bytes_add, expected_add, "add(a, b) を x86_64 にエンコード (2-operand 化)")

puts ""
puts "#{$pass} passed, #{$fail} failed (JIT x86_64 encoder unit)"
exit($fail == 0 ? 0 : 1)
