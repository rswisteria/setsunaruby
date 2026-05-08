# Stage 4a: ビット演算と論理演算のデモ。
# `<<` は両辺 Fixnum なら整数左シフトに dispatch される (String/Array << は引き続き動作)。

# ---- ビット演算 ----
puts 1 << 3            # 8 (左シフト)
puts 8 >> 2            # 2 (右シフト)
puts 12 & 10           # 8  (AND)
puts 12 | 10           # 14 (OR)
puts 12 ^ 10           # 6  (XOR)
puts ~0                # -1 (NOT)
puts (1 << 3) | 6      # 14 (Issue #39 完了基準)
puts 255 & 15          # 15 (= 0xff & 0x0f。16 進リテラルは Stage 4a では未対応)

# ---- 論理演算 ----
puts !true             # false
puts !false            # true
puts !nil              # true
puts !0                # false (0 は truthy)
puts 1 != 2            # true
puts true && false     # false (短絡)
puts false || true     # true
puts nil || 7          # 7    (lhs が偽なら rhs を返す)

# ---- 短絡評価で副作用が走らないこと ----
x = 0
if false && (x = 1)
  puts "in-then"
end
puts x   # 0 のまま (rhs は評価されない)

# ---- 演算子優先順位 (Ruby と同じ) ----
puts 1 + 2 << 1        # 6  ((1+2) << 1)
puts 1 << 2 | 1        # 5  ((1<<2) | 1)
puts 1 == 1 && 2 == 2  # true

# ---- packed name 風の式 (interp.rb 内部で多用される形) ----
start = 5
len = 3
puts (start << 16) | len   # 327683
