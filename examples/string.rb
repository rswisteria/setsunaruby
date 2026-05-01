# Stage 3a: 文字列リテラル・連結 (+) ・追加 (<<) ・比較 (==) ・puts 出力。
puts "hello, setsunaruby"
puts "tab\there"
puts "line1\nline2"

s = "Stage " + "3a"
puts s

buf = ""
i = 0
while i < 5
  buf << "*"
  i = i + 1
end
puts buf

if buf == "*****"
  puts "ok"
else
  puts "ng"
end
