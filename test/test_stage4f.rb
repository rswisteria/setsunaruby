$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'setsunaruby/interp'
require 'stringio'
require 'tempfile'

$pass = 0
$fail = 0

# Stage 4f: AOT バイナリには push_argv API を持たせない (spinel の whole-program 推論を
# 壊さないため)。CRuby テストでは prepare_for_run と execute_loaded_program の間に
# internal helper を `send` 経由で呼んで ARGV を構築する。
def setup_argv_entry(interp, s)
  arr_id = interp.instance_variable_get(:@argv_obj_id)
  if arr_id == 0  # NIL_VAL
    arr_id = interp.send(:heap_array_alloc, 0)
    interp.instance_variable_set(:@argv_obj_id, arr_id)
  end
  str_id = interp.send(:alloc_string_from_ruby_string, s)
  interp.send(:heap_array_push_bang, arr_id, str_id)
end

def run_source(src, argv_strings = [])
  buf      = StringIO.new
  err_buf  = StringIO.new
  saved_out = $stdout
  saved_err = $stderr
  $stdout = buf
  $stderr = err_buf
  begin
    interp = Setsunaruby::Interp.new
    interp.prepare_for_run(src)
    argv_strings.each do |s|
      setup_argv_entry(interp, s)
    end
    interp.execute_loaded_program
  ensure
    $stdout = saved_out
    $stderr = saved_err
  end
  [buf.string, err_buf.string]
end

def assert_output(src, expected, label, argv_strings = [])
  actual, _err = run_source(src, argv_strings)
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

def assert_stderr(src, expected, label, argv_strings = [])
  _out, actual = run_source(src, argv_strings)
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

def assert_exits(src, expected_status, label, argv_strings = [])
  ok = false
  actual_status = nil
  saved_out = $stdout
  saved_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  begin
    interp = Setsunaruby::Interp.new
    interp.prepare_for_run(src)
    argv_strings.each { |s| setup_argv_entry(interp, s) }
    interp.execute_loaded_program
  rescue SystemExit => e
    ok = true
    actual_status = e.status
  ensure
    $stdout = saved_out
    $stderr = saved_err
  end
  if ok && actual_status == expected_status
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label} (expected SystemExit status=#{expected_status}, got status=#{actual_status.inspect} raised=#{ok})"
  end
end

def assert_raises(src, label, argv_strings = [])
  ok = false
  saved_out = $stdout
  saved_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  begin
    interp = Setsunaruby::Interp.new
    interp.prepare_for_run(src)
    argv_strings.each { |s| setup_argv_entry(interp, s) }
    interp.execute_loaded_program
  rescue StandardError, SystemExit
    ok = true
  ensure
    $stdout = saved_out
    $stderr = saved_err
  end
  if ok
    $pass += 1
    puts "ok   #{label}"
  else
    $fail += 1
    puts "FAIL #{label} (expected to raise)"
  end
end

# ---- File.read ----
hello_path = File.expand_path('../examples/hello.rb', __dir__)
hello_body = File.read(hello_path)
assert_output("puts File.read(\"#{hello_path}\")\n", hello_body, "FILE_READ: hello.rb 全文")
assert_output("s = File.read(\"#{hello_path}\")\nputs s.bytes.length > 0\n", "true\n",
              "FILE_READ: 戻り値は長さ > 0 の String (.bytes.length で確認)")
# 一時ファイルを作って中身を確認
tmp = Tempfile.new(['stage4f_', '.txt'])
tmp.write("alpha\nbeta\n")
tmp.close
assert_output("puts File.read(\"#{tmp.path}\")\n", "alpha\nbeta\n",
              "FILE_READ: 任意ファイル (内容は末尾改行を含む)")
tmp.unlink

# 存在しないファイルは例外
assert_raises("puts File.read(\"/nonexistent/path/zzz.rb\")\n", "FILE_READ: 存在しないファイルで raise")
# 引数の型が String でないと TypeError
assert_raises("puts File.read(123)\n", "FILE_READ: Integer 引数で raise")

# ---- ARGV ----
assert_output("puts ARGV.length\n", "0\n", "ARGV: 引数なし → length 0", [])
assert_output("puts ARGV.length\n", "3\n", "ARGV: 3 引数 → length 3", ["a", "b", "c"])
assert_output("puts ARGV[0]\n",     "hello\n", "ARGV: ARGV[0]", ["hello"])
assert_output("puts ARGV[2]\n",     "z\n",     "ARGV: ARGV[2]", ["x", "y", "z"])
# ARGV を each で回す
argv_iter = <<~RUBY
  i = 0
  while i < ARGV.length
    puts ARGV[i]
    i = i + 1
  end
RUBY
assert_output(argv_iter, "first\nsecond\n", "ARGV: while で iterate", ["first", "second"])
# ARGV の要素は heap String なので #bytes も呼べる
assert_output("puts ARGV[0].bytes\n", "97\n98\n99\n", "ARGV: 要素は heap String (bytes 呼べる)", ["abc"])

# ---- STDERR ----
assert_stderr("STDERR.puts(\"hi\")\n", "hi\n", "STDERR: 1 行出力")
assert_output("STDERR.puts(\"err\")\n", "", "STDERR: stdout には出ない")
assert_stderr("STDERR.puts(\"a\")\nSTDERR.puts(\"b\")\n", "a\nb\n", "STDERR: 連続出力")
# Integer / Array も puts できる (to_puts_string 経由)
assert_stderr("STDERR.puts(42)\n", "42\n", "STDERR: Integer も出力")

# ---- exit ----
assert_exits("exit 0\n",        0, "EXIT: status 0")
assert_exits("exit 1\n",        1, "EXIT: status 1")
assert_exits("exit 42\n",       42, "EXIT: 任意 status")
assert_exits("exit\n",          0, "EXIT: 引数なしは status 0")
assert_exits("puts \"a\"\nexit 1\nputs \"b\"\n", 1,
             "EXIT: 後続コード到達せず status 1")

# ---- 複合 ----
combined = <<~RUBY
  if ARGV.length == 0
    STDERR.puts("no args")
    exit 1
  end
  puts ARGV[0]
RUBY
# 引数なしで stderr + exit 1
saved_out = $stdout
saved_err = $stderr
$stdout = StringIO.new
err_buf = StringIO.new
$stderr = err_buf
ok = false
status = nil
begin
  Setsunaruby::Interp.new.run_string(combined)
rescue SystemExit => e
  ok = true
  status = e.status
ensure
  $stdout = saved_out
  $stderr = saved_err
end
if ok && status == 1 && err_buf.string == "no args\n"
  $pass += 1
  puts "ok   MIX: ARGV.length==0 で stderr + exit 1"
else
  $fail += 1
  puts "FAIL MIX (status=#{status.inspect} stderr=#{err_buf.string.inspect})"
end

# 引数ありで通常出力
assert_output(combined, "first\n", "MIX: ARGV ありで通常 path", ["first"])

puts ""
puts "#{$pass} passed, #{$fail} failed (Stage 4f)"
exit($fail == 0 ? 0 : 1)
