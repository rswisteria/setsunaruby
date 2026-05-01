# Stage 3c.3: Array#map / 中括弧ブロック / block_given?

# 1. map で平方数を作る
squared = [1, 2, 3, 4, 5].map { |x| x * x }
puts squared

# 2. 中括弧ブロックは do/end と同じ
counts = [10, 20, 30].map do |v|
  v / 10
end
puts counts

# 3. block_given? でオプショナルブロック
def announce(name)
  if block_given?
    yield name
  else
    puts "Hello, " + name
  end
end

announce("world")
announce("setsunaruby") { |n| puts "Welcome, " + n + "!" }

# 4. map + yield (method 内で外側のブロックを呼ぶ)
def transform(arr)
  arr.map { |x| yield x }
end
puts transform([1, 2, 3]) { |x| x + 100 }
