# Stage 3a + GC-1/GC-2 ベンチ: 短命文字列を大量生成して GC のスループットを測る。
# 各反復で "abc" + "def" を heap String として生成し、"abcdef" と値比較する。
# alloc は 1 反復あたり 4 個 (PUSH_STR x 3 + 連結 1)、5000 反復で約 20 回 GC が起動。
def count_match(n)
  count = 0
  i = 0
  while i < n
    s = "abc" + "def"
    if s == "abcdef"
      count = count + 1
    end
    i = i + 1
  end
  count
end

puts count_match(5000)
