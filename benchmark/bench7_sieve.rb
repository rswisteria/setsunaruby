# Stage 3b ベンチ: エラトステネスの篩で 0..N の素数を数える。
# N=5000 で 669 個。配列の index 操作 + 二重 while ループのスループットを測る。
def sieve(limit)
  flags = []
  i = 0
  while i <= limit
    flags << 1
    i = i + 1
  end
  flags[0] = 0
  flags[1] = 0
  i = 2
  while i <= limit
    if flags[i] == 1
      j = i + i
      while j <= limit
        flags[j] = 0
        j = j + i
      end
    end
    i = i + 1
  end
  count = 0
  i = 0
  while i <= limit
    if flags[i] == 1
      count = count + 1
    end
    i = i + 1
  end
  count
end

puts sieve(5000)
