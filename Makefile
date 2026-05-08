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
	ruby test/test_stage3a.rb
	ruby test/test_stage3b.rb
	ruby test/test_stage3c1.rb
	ruby test/test_stage3c2.rb
	ruby test/test_stage3c3.rb
	ruby test/test_stage3d1.rb
	ruby test/test_stage3d2.rb
	ruby test/test_stage3d3.rb
	ruby test/test_stage3d4.rb
	ruby test/test_stage3d5.rb
	ruby test/test_stage3e.rb
	ruby test/test_stage4a.rb
	ruby test/test_stage_jit.rb
	ruby test/test_gc.rb

test-aot: build
	ruby test/test_aot.rb

test-all: test-cruby test-aot

bench: build
	ruby benchmark/run_bench.rb

bench-regen:
	ruby benchmark/gen_benchmarks.rb

clean:
	rm -f setsunaruby setsunaruby.c
