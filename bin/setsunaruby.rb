require_relative '../lib/setsunaruby/lexer'
require_relative '../lib/setsunaruby/parser'
require_relative '../lib/setsunaruby/compiler'
require_relative '../lib/setsunaruby/vm'

if ARGV.length != 1
  STDERR.puts "usage: setsunaruby <file.rb>"
  exit 1
end

src      = File.read(ARGV[0])
tokens   = Setsunaruby::Lexer.new(src).tokenize
program  = Setsunaruby::Parser.new(tokens).parse_program
bytecode = Setsunaruby::Compiler.new.compile(program)
Setsunaruby::VM.new(bytecode).run
