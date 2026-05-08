# GC: ガベージコレクタ

setsunaruby の VM がヒープオブジェクト (`String` / `Array` / インスタンス) の
死んだ slot を回収するための仕組み。Stage GC-1 で **Stop-the-World Mark-Sweep**
を導入し、heap slot のみを回収する。pool 系 (`@str_pool` / `@heap_arr_pool` /
`@instance_ivar_pool`) の圧縮は Stage GC-2 で対応予定。

## ヒープモデルのおさらい

ヒープは並列 IntArray の SoA + 3 種類の flat pool で構成される
(詳細は [bytecode/overview.md](../bytecode/overview.md))。

| 領域 | 役割 |
|---|---|
| `@heap_kind[idx]` | slot の種別 (0=tombstone, 1=String, 2=Array, 3=Instance) |
| `@heap_starts[idx]` / `@heap_lens[idx]` | kind に応じた pool への offset / 長さ |
| `@heap_instance_class[idx]` | Instance のときの class idx (それ以外は -1) |
| `@heap_marked[idx]` | **GC-1 で追加**。mark 用ビット (0=未 mark, 1=live) |
| `@str_pool` | String のバイト列 (`@strlit_starts` / `@strlit_lens` 経由でリテラルも参照) |
| `@heap_arr_pool` | Array 要素 (`obj_id` を保持) |
| `@instance_ivar_pool` | Instance ivar (`obj_id` を保持) |

`obj_id = (idx << 3) | HEAP_TAG`、即値 (Fixnum / nil / true / false) との区別は
下位 3 bit の `HEAP_TAG = 6` で行う。

## なぜ GC が必要か

GC-1 以前は `alloc_heap_slot` が `@heap_kind` 等を append-only で増やし続けるため、
heap slot が単調に積み上がっていた。短命オブジェクトを大量生成するパターン
(文字列連結ループ、配列構築、ブロックでの中間値) で `@heap_kind.length` が
線形に膨張し、長時間実行・自己ホストで実用にならない。

## アルゴリズム (Stage GC-1)

### ルートセット

| ルート | 内容 |
|---|---|
| `@stack` | VM 評価スタック (IntArray of obj_id) |
| `@locals` | ローカル変数領域 (frame 切り替え時の view は `@cur_base`) |
| `@cfp_selfs` | コールフレームごとの receiver |
| `@cur_self` | 現在実行中フレームの receiver |
| `@exception` | 伝播中の例外オブジェクト (`NIL_VAL` のとき無し) |

`@strlit_starts` / `@strlit_lens` は `@str_pool` への直接 offset であり heap slot
を介さない。GC-1 では pool を一切触らないため、リテラルバイト領域も影響を受けない。

### Mark phase

1. `@heap_marked` を slot 数分 0 リセット
2. ルートを順に `gc_push_root(v)` に渡す
   - `(v & 7) != HEAP_TAG` ならスキップ (即値)
   - すでに mark 済みならスキップ
   - mark を立て、idx を `@gc_mark_stack` に push
3. `gc_drain_mark_stack` で BFS:
   - `@heap_kind[idx]` が `HEAP_KIND_ARRAY` → `@heap_arr_pool[start..start+len)` を再 push
   - `HEAP_KIND_INSTANCE` → `@instance_ivar_pool[start..start+len)` を再 push
   - `HEAP_KIND_STRING` は終端 (バイトのみで `obj_id` を含まない)

再帰関数ではなく explicit stack で実装している理由は (a) spinel が深い再帰関数を
素直に C 化しないことがある、(b) 大きな配列で C スタック溢れを避ける、の 2 点。

### Sweep phase

`@heap_kind` を線形に走査し、未 mark かつ tombstone でない slot を tombstone 化:

```
@heap_kind[i] = HEAP_KIND_TOMBSTONE   # = 0
@heap_freelist.push(i)
```

### 閾値の更新

GC 後の live slot 数 (= `@heap_kind.length - @heap_freelist.length`) の 2 倍を
新しい `@gc_threshold` とする (最低 1024)。これにより GC overhead が live セット
サイズに対して償却される。

## アロケーション経路 (`alloc_heap_slot`)

```
def alloc_heap_slot(kind, start, len, class_idx)
  live_count = @heap_kind.length - @heap_freelist.length
  if live_count >= @gc_threshold
    gc_collect          # 必要なら STW GC を起動
  end
  if @heap_freelist.length > 0
    idx = @heap_freelist.pop
    # @heap_kind / @heap_starts / @heap_lens / @heap_instance_class /
    # @heap_marked の 5 並列を上書きし、idx を再利用
  else
    # 5 並列に push (heap.length が伸びる)
  end
end
```

`alloc` の 1 箇所だけが GC を起動する。VM の他の op (CALL / RETURN / 算術等) は
直接 GC を呼ばない。bytecode 境界のうち alloc 経路を含む op だけが暗黙の safepoint
になる、というモデル。

GC が何も解放しなかった場合 (= 全 slot が live) は `@heap_freelist` が空のまま
`alloc_heap_slot` の else 経路で `@heap_kind` が伸びる。ただし `@gc_threshold` が
`live * 2` に更新されるため、次の GC は実質倍の alloc 数まで遅延される (アロケーション
レートの肥大に応じてヒープと閾値が同調的に伸びる)。

## spinel 互換のための工夫

CLAUDE.md の強制ルールを順守:

- **再帰なし** — `gc_drain_mark_stack` は explicit stack で BFS 化
- **bool ローカル変数を分岐に使わない** (rule 11) — すべて条件式直接判定 / Integer カウンタ
- **kind タグは Integer 定数** — `HEAP_KIND_TOMBSTONE = 0` を `HEAP_KIND_*` 群に追加。
  既存の `heap_str?` `heap_array?` は `@heap_kind[idx] == HEAP_KIND_*` で値比較する
  ため、tombstone (= 0) は自然に「いずれの型でもない」と弁別される
- **戻り値の中間変数化** (rule 6) — `alloc_heap_slot` は `result = 0` で初期化、
  if 各分岐で `result = box_heap(...)` 代入、最後に `result` を返す形

## デバッグ

`SETSUNARUBY_DUMP_GC=1` を環境変数に設定すると、各 GC 実行時に STDERR へ
1 行統計を吐く:

```
[gc] live=N freed=M threshold=T
```

`@dump_hir` (`SETSUNARUBY_DUMP_HIR`) と同じパターン。

## 現状の制限と後続

- **pool は圧縮されない** — `@str_pool` / `@heap_arr_pool` の relocate-and-grow による
  abandoned 領域は積もり続ける。Stage GC-2 で前詰めを導入する
- **slot は前詰めしない** — `@heap_kind.length` 自体は伸びたまま (tombstone を
  freelist で再利用するので「実効サイズ」は頭打ち)。Stage GC-3 (任意) で forwarding
  table 付きの slot compaction を検討
- **JIT 案 C 連携なし** — JIT-4 案 A は機械語ダンプのみで実機実行していない
  (詳細は [jit/status.md](../jit/status.md))。案 C 導入時に safepoint 設計が必要

## 参照箇所 (`lib/setsunaruby/interp.rb`)

- 定数: `HEAP_KIND_TOMBSTONE` 〜 `HEAP_KIND_INSTANCE`
- ivar: `@heap_marked` / `@heap_freelist` / `@gc_mark_stack` / `@gc_threshold` / `@dump_gc`
- メソッド: `gc_collect` / `gc_push_root` / `gc_drain_mark_stack` / `alloc_heap_slot`
