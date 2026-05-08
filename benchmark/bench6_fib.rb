# Stage 2 ベンチ: 単純再帰 fib の関数呼び出しオーバーヘッドを測る。
# fib(28) = 317811。AOT は CRuby 比で 20-30x の speedup を出すはず。
def fib(n)
  if n < 2
    n
  else
    fib(n - 1) + fib(n - 2)
  end
end

puts fib(28)
