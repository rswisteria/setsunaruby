# Stage 3e: 例外処理のショーケース。

# 文字列 raise → 暗黙の StandardError ラップ
begin
  raise "boom"
rescue => e
  puts e.message
end

# ユーザ定義 < StandardError + rescue 親クラス
class ValidationError < StandardError
end

class TooShortError < ValidationError
end

def check(s)
  if s == ""
    raise TooShortError.new("input is empty")
  end
  s
end

begin
  puts check("hello")
  puts check("")
rescue ValidationError => e
  puts "validation failed: " + e.message
end

# ensure はどのパスでも実行される
def with_resource(should_fail)
  begin
    if should_fail
      raise "boom"
    end
    puts "work"
  ensure
    puts "cleanup"
  end
end

with_resource(false)
begin
  with_resource(true)
rescue => e
  puts "got: " + e.message
end

# block 内 raise → 上位へ伝播
def each_with_safety
  yield 1
  yield 2
  yield 3
  puts "done"
end

begin
  each_with_safety do |i|
    if i == 2
      raise "stop at 2"
    end
    puts i
  end
rescue => e
  puts "interrupted: " + e.message
end

# 複数 rescue 節
class Net < StandardError
end
class Auth < StandardError
end

def call(kind)
  if kind == 1
    raise Net.new("net down")
  end
  if kind == 2
    raise Auth.new("forbidden")
  end
  "ok"
end

begin
  call(2)
rescue Net => e
  puts "net: " + e.message
rescue Auth => e
  puts "auth: " + e.message
end
