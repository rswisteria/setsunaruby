# JIT の動作状況と残タスク

JIT は **案 A (機械語ダンプまで) で完成**、**案 C (実機実行) は未着手**。
未着手部分は spinel ランタイム拡張に依存している。

## 動作している範囲 (案 A)

`SETSUNARUBY_DUMP_HIR=1 ruby bin/setsunaruby.rb examples/fib.rb 2>&1` で以下が
確認できる:

- ホット検出ログ (`ZJIT: hot method detected (idx=N)`)
- HIR (raw / optimized) のダンプ
- CFG analysis (idom / DF) のダンプ
- LIR + arm64 機械語 hex のダンプ

これらはすべて STDERR への出力で、実際の bytecode 実行には影響しない。
通常実行は VM が `@bytecode` を解釈する経路で行われる。

## 動作していない範囲 (案 C)

生成した機械語を CPU に実行させる経路は未実装。実装には次の 4 機能が必要で、
いずれも spinel が現状サポートしていない低レベル C ランタイムに踏み込む。

### 1. 実行可能メモリの確保 (`mmap`)

```c
void *buf = mmap(NULL, size,
                 PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
```

Ruby から `mmap(2)` を呼ぶ手段が無い。spinel 側で `Kernel#mmap` 相当のブリッジを
提供する必要がある。

### 2. W^X (Apple Silicon) の保護切替

macOS arm64 では同一ページに同時に W (write) と X (execute) の両方を持てない
(W^X protection)。JIT 用には:

```c
pthread_jit_write_protect_np(0);  // 書き込み許可
memcpy(buf, machine_code, size);   // 機械語コピー
pthread_jit_write_protect_np(1);   // 実行許可
```

の API を呼ぶ必要がある。`MAP_JIT` フラグ付き `mmap` も含めて、JIT 専用の
特別な API 群が要る。spinel が macOS arm64 をターゲットにするなら個別対応が必須。

### 3. 関数ポインタ呼び出し

確保した buffer を関数ポインタにキャストして呼ぶ部分:

```c
typedef int64_t (*jit_fn)(int64_t arg0, int64_t arg1);
jit_fn fn = (jit_fn) buf;
int64_t result = fn(a, b);
```

これに対応する Ruby 側の表現が無い。spinel が C 側の関数ポインタ呼び出しを
Ruby メソッドとして公開できれば動く。引数渡し規約 (X0..X7 に整数引数) に従う
必要があり、generic な Ruby メソッド呼び出しでは賄えない。

### 4. キャッシュフラッシュ

arm64 では生成した機械語をプロセッサに fetch させる前に I-cache / D-cache の
フラッシュが必要:

```c
__builtin___clear_cache(buf, buf + size);
```

これも spinel 拡張前提。

## ロードマップ

| 案 | 完了度 | 内容 |
|---|---|---|
| A: ダンプまで | ✅ 完成 | HIR/LIR/機械語 hex を STDERR にダンプ。教育目的・設計検証の手段として完備 |
| B: (検討中) | — | mmap の代わりに `dlopen(3)` で動的に C ライブラリをロードする等の中間案 |
| C: 実機実行 | ❌ 未着手 | mmap + W^X + 関数ポインタ呼び出し + キャッシュフラッシュをすべて実装 |

## なぜ案 A まで実装したか

- JIT 各サブステージの設計が ZJIT 本家相当の表現力に達していることを **構造的に
  検証する** 手段として、ダンプは十分に有用
- SoA + kind tag + spinel 制約下で「どこまで JIT らしき構造を Ruby サブセットで
  書けるか」が実証できる
- 実機実行は **spinel 機能不足** に起因しており、setsunaruby 本体の Ruby サブセット
  表現力の問題ではない (= 切り分け済み)

## CRuby と AOT での挙動差

`SETSUNARUBY_DUMP_HIR=1` のダンプは **CRuby 実行時のみ** 視認できる。spinel AOT は
`STDERR.puts` を silent な no-op にコンパイルするため、AOT バイナリではログが出ない。
カウンタ更新・HIR 構築・最適化パス・LIR lower・arm64 エンコードの**ロジックそのものは
AOT でも動作している** (test_aot.rb で副作用がないことは確認済み)。
