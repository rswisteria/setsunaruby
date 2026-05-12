# Stage 4e: String#bytes / Integer#chr / String#chr / Object#nil?。
# 自己ホスト (#6) の Lexer 風コードに必要な byte 操作 API のデモ。

# String を byte 配列に
puts "abc".bytes      # 97 / 98 / 99

# 個別 byte を Integer として取り出して比較
b = "0a9".bytes
puts b[0]             # 48 = '0'
puts b[1]             # 97 = 'a'
puts b[2]             # 57 = '9'

# Integer → 1 文字 String (chr)
puts 65.chr           # A
puts 32.chr.bytes     # 32

# String の最初の 1 文字
puts "hello".chr      # h

# 各 byte を chr 経由で 1 つの String にまとめる
src    = "Xyz"
bytes  = src.bytes
joined = ""
i = 0
while i < bytes.length
  joined << bytes[i].chr
  i = i + 1
end
puts joined           # Xyz

# Object#nil?: nil 判定
puts nil.nil?         # true
puts 0.nil?           # false
puts "".nil?          # false
puts false.nil?       # false

# 条件付きの典型用法
def first_or_default(arr, default)
  v = arr.last
  if v.nil?
    default
  else
    v
  end
end

puts first_or_default([1, 2, 3], 999)   # 3
puts first_or_default([], 999)          # 999
