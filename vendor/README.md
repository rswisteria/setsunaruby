# vendor/

setsunaruby が前提とする外部成果物の保管所。

## `spinel-jit-primitives.patch`

`~/spinel` の `master` に対して setsunaruby が要求する `module JIT` 拡張一式。
**upstream には送らない** 個人フォーク。`~/spinel` を別マシンに clone した直後など、
パッチ未適用の状態から復旧する手順:

```bash
cd ~/spinel
git checkout -b setsunaruby-jit master
git am < /path/to/setsunaruby/vendor/spinel-jit-primitives.patch
make deps       # 初回のみ
make            # spinel_codegen を再生成 (= ブートストラップ)
```

`make build` (setsunaruby) は事前に `verify-spinel-jit` ターゲットで
`~/spinel/lib/sp_runtime.h` に `sp_jit_alloc` シンボルがあるかを確認する。

パッチが当たっていれば `setsunaruby` ビルドは JIT 実機実行経路を有効化できる
(spinel 拡張定数 `JIT::DARWIN_ARM64` / `JIT::PROT_*` 等を参照可能になる)。
