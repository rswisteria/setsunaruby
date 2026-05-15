SPINEL      ?= $(HOME)/spinel/spinel
SPINEL_HOME ?= $(HOME)/spinel
ENTRY       := bin/setsunaruby.rb

.PHONY: all build run-cruby clean test verify-spinel-jit

all: build

# spinel が setsunaruby-jit ブランチ (= JIT primitives 適用済み) かをチェック。
# vendor/spinel-jit-primitives.patch を当て直して `cd ~/spinel && make` で復旧。
verify-spinel-jit:
	@grep -q 'sp_jit_alloc' $(SPINEL_HOME)/lib/sp_runtime.h \
	  || { echo "ERROR: spinel に JIT primitives 未適用。"; \
	       echo "  cd $(SPINEL_HOME) && git am < $(CURDIR)/vendor/spinel-jit-primitives.patch && make"; \
	       exit 1; }

# spinel で AOT ビルド
build: verify-spinel-jit
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
	ruby test/test_stage4b.rb
	ruby test/test_stage4c.rb
	ruby test/test_stage5a.rb
	ruby test/test_stage_jit.rb
	ruby test/test_gc.rb

test-aot: build
	ruby test/test_aot.rb

# x86_64 エンコーダの byte 列単体テスト (CRuby 上、macOS arm64 でも検証可)。
test-jit-x86-64:
	ruby test/test_jit_x86_64.rb

# JIT 再帰 / multi-BB 実行テスト (arm64 ホスト + SETSUNARUBY_JIT=1 で fib 完走)。
test-jit-recursion: build
	ruby test/test_jit_recursion.rb

test-all: test-cruby test-aot test-jit-x86-64 test-jit-recursion

bench: build
	ruby benchmark/run_bench.rb

# JIT 有無のパフォーマンス比較 (CRuby / AOT / AOT+JIT の 3 系統)。
# spinel fork が必要 (verify-spinel-jit 経由で確認)。
bench-jit: build
	ruby benchmark/run_bench_jit.rb

bench-regen:
	ruby benchmark/gen_benchmarks.rb

clean:
	rm -f setsunaruby setsunaruby.c
