# Stage 3d + GC ベンチ: クラス + ivar + メソッド dispatch + 再帰 + GC 圧力。
# 1000 ノードの片方向 LinkedList を作って合計を再帰メソッドで計算する。
# 1+2+...+1000 = 500500 が答え。
class Node
  def initialize(val, nxt)
    @val = val
    @nxt = nxt
  end

  def sum
    if @nxt == nil
      @val
    else
      @val + @nxt.sum
    end
  end
end

n = 1000
head = nil
i = 0
while i < n
  head = Node.new(i + 1, head)
  i = i + 1
end
puts head.sum
