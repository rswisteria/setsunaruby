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

test:
	ruby test/test_stage0.rb

clean:
	rm -f setsunaruby setsunaruby.c
