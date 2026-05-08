# Stage 2 + 3b ベンチ: N-queens の解の数を再帰バックトラックで数える。
# N=10 で 724 解。再帰の深さ 10、各レベルで 10 通りの試行 → 約 35 万回の安全判定。
def safe?(cols, row, col)
  i = 0
  while i < row
    c = cols[i]
    if c == col
      return false
    end
    diff = row - i
    if c == col - diff
      return false
    end
    if c == col + diff
      return false
    end
    i = i + 1
  end
  true
end

def solve(cols, row, n)
  if row == n
    return 1
  end
  count = 0
  col = 0
  while col < n
    if safe?(cols, row, col)
      cols[row] = col
      count = count + solve(cols, row + 1, n)
    end
    col = col + 1
  end
  count
end

n = 10
cols = []
i = 0
while i < n
  cols << 0
  i = i + 1
end
puts solve(cols, 0, n)
