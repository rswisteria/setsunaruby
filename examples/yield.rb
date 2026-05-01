# Stage 3c.2: ユーザ定義のブロック取り method と yield。

# 自前 each — Stage 3c.1 の組み込み each と等価な実装。
def my_each(arr)
  i = 0
  while i < arr.length
    yield arr[i]
    i = i + 1
  end
end

my_each([10, 20, 30]) do |x|
  puts x
end

# yield の戻り値を集めて新しい配列を返す (map 自前実装)。
def my_map(arr)
  out = []
  i = 0
  while i < arr.length
    out << yield arr[i]
    i = i + 1
  end
  out
end

doubled = my_map([1, 2, 3, 4]) do |x|
  x * 2
end
puts doubled

# yield 引数なし。
def repeat(n)
  i = 0
  while i < n
    yield
    i = i + 1
  end
end

repeat(3) do
  puts "hi"
end

# closure: ブロックが caller の変数を更新する。
def for_each(arr)
  arr.each do |x|
    yield x
  end
end

sum = 0
for_each([1, 2, 3, 4, 5]) do |v|
  sum = sum + v
end
puts sum
