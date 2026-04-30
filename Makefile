SPINEL ?= $(HOME)/spinel/spinel
ENTRY  := bin/setsunaruby.rb

.PHONY: all build run-cruby clean test

all: build

# spinel で AOT ビルド
build:
	$(SPINEL) $(ENTRY) -o setsunaruby

# CRuby で開発時実行 (例: make run-cruby ARGS=examples/hello.rb)
run-cruby:
	ruby $(ENTRY) $(ARGS)

test: test-cruby

test-cruby:
	ruby test/test_stage0.rb
	ruby test/test_stage1.rb
	ruby test/test_stage2.rb

test-aot: build
	ruby test/test_aot.rb

test-all: test-cruby test-aot

bench: build
	ruby benchmark/run_bench.rb

bench-regen:
	ruby benchmark/gen_benchmarks.rb

clean:
	rm -f setsunaruby setsunaruby.c
