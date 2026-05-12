# JIT ベンチ: 再帰 fib(28) を JIT で実機実行。
# install 拒否を避けるため明示的ローカル `result = ...` 経由 (PR #51 の dominance check
# が if-expression 戻り値の不完全な HIR を弾くため)。
# 期待: AOT/JIT 比は大。再帰の各フレームが BL→prologue→body→epilogue→RET で機械語直行。
def fib(n)
  result = 0
  if n < 2
    result = n
  else
    result = fib(n - 1) + fib(n - 2)
  end
  result
end

puts fib(28)
