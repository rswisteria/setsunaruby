# Stage 1 のローカル変数 + 制御構造 (if/while) のショーケース。
# 文字列リテラルは未実装なので、Fizz/Buzz/FizzBuzz の代わりに整数値で出力する。
#   FizzBuzz → -1, Fizz → -3, Buzz → -5
i = 1
while i <= 30
  if i % 15 == 0
    puts -1
  elsif i % 3 == 0
    puts -3
  elsif i % 5 == 0
    puts -5
  else
    puts i
  end
  i = i + 1
end
