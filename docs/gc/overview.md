# GC: ガベージコレクタ

setsunaruby の VM がヒープオブジェクト (`String` / `Array` / インスタンス) の
死んだ slot と pool 領域を回収するための仕組み。

- **Stage GC-1**: STW Mark-Sweep による heap slot 回収 (free list 再利用)
- **Stage GC-2**: mark phase 直後に 3 つの flat pool (`@str_pool` / `@heap_arr_pool` /
  `@instance_ivar_pool`) を前詰めし、relocate-and-grow による abandoned 領域を回収

## ヒープモデルのおさらい

ヒープは並列 IntArray の SoA + 4 種類の flat pool で構成される
(詳細は [bytecode/overview.md](../bytecode/overview.md))。

| 領域 | 役割 |
|---|---|
| `@heap_kind[idx]` | slot の種別 (0=tombstone, 1=String, 2=Array, 3=Instance) |
| `@heap_starts[idx]` / `@heap_lens[idx]` | kind に応じた pool への offset / 長さ |
| `@heap_instance_class[idx]` | Instance のときの class idx (それ以外は -1) |
| `@heap_marked[idx]` | **GC-1 で追加**。mark 用ビット (0=未 mark, 1=live) |
| `@str_pool` | heap String slot 専用のバイトプール (**GC-2 で圧縮対象**) |
| `@strlit_pool` | **GC-2 で追加**。lex 時の literal バイト専用プール (不変・GC 対象外) |
| `@strlit_starts` / `@strlit_lens` | `@strlit_pool` 上の offset / length |
| `@heap_arr_pool` | Array 要素 (`obj_id` を保持、**GC-2 で圧縮対象**) |
| `@instance_ivar_pool` | Instance ivar (`obj_id` を保持、**GC-2 で圧縮対象**) |

`obj_id = (idx << 3) | HEAP_TAG`、即値 (Fixnum / nil / true / false) との区別は
下位 3 bit の `HEAP_TAG = 6` で行う。

## なぜ GC が必要か

GC-1 以前は `alloc_heap_slot` が `@heap_kind` 等を append-only で増やし続けるため、
heap slot が単調に積み上がっていた。短命オブジェクトを大量生成するパターン
(文字列連結ループ、配列構築、ブロックでの中間値) で `@heap_kind.length` が
線形に膨張し、長時間実行・自己ホストで実用にならなかった。

更に `@str_pool` と `@heap_arr_pool` は relocate-and-grow を採用しており
(`heap_str_concat` / `heap_array_push_bang` の旧領域は abandon)、slot を回収しても
pool バイトは積もり続ける。GC-2 はこの pool 側の積み上がりを解消する。

## アルゴリズム

`gc_collect` の全体フロー:

```
0. mark stack reset (defensive)
1. @heap_marked を 0 リセット
2. ルート 5 種を mark stack に push
3. drain (BFS で child を辿って mark)
3.5. (GC-2) live slot の中身を 3 つの pool に前詰め
4. sweep (未 mark slot を tombstone 化、freelist へ)
5. threshold 更新 (live * 2、最低 1024)
```

### ルートセット

| ルート | 内容 |
|---|---|
| `@stack` | VM 評価スタック (IntArray of obj_id) |
| `@locals` | ローカル変数領域 (frame 切り替え時の view は `@cur_base`) |
| `@cfp_selfs` | コールフレームごとの receiver |
| `@cur_self` | 現在実行中フレームの receiver |
| `@exception` | 伝播中の例外オブジェクト (`NIL_VAL` のとき無し) |

`@strlit_starts` / `@strlit_lens` は `@strlit_pool` への直接 offset であり heap slot
を介さない。**`@strlit_pool` は lex 時に確定する不変領域なので GC 対象外** であり、
heap String の `@str_pool` 圧縮 (GC-2) とは独立に保たれる。

### Mark phase (GC-1)

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

### Pool compaction (GC-2)

`gc_compact_pools` が mark phase 直後 / sweep phase 直前に呼ばれる。

```
new_str_pool, new_heap_arr_pool, new_ivar_pool = [], [], []
i = 0
while i < @heap_kind.length
  if @heap_marked[i] == 1
    k = @heap_kind[i]
    old_start, l = @heap_starts[i], @heap_lens[i]
    if k == HEAP_KIND_STRING
      new_start = new_str_pool.length
      copy @str_pool[old_start, l] -> new_str_pool
      @heap_starts[i] = new_start
    elsif k == HEAP_KIND_ARRAY
      ... new_heap_arr_pool に同様
    elsif k == HEAP_KIND_INSTANCE
      ... new_ivar_pool に同様
    end
  end
  i += 1
end
@str_pool, @heap_arr_pool, @instance_ivar_pool = new_*
```

設計上のポイント:

- **slot idx は不変**: `@heap_arr_pool` / `@instance_ivar_pool` 内の `obj_id` は
  idx 参照なので、要素を新 pool にコピーしても値の書き換えは不要
- **mark 直後に圧縮する理由**: tombstone (kind=0) と未 mark を区別する判定が `@heap_marked == 1`
  の 1 行で済み、sweep より前に処理することで分岐が単純になる
- **`@strlit_pool` は触らない**: 不変領域であり、heap String 用の `@str_pool` から完全に
  分離されている (前段リファクタで `parse_string_lit` を `@strlit_pool` ベースに変更済み)
- **`@strlit_starts` / `@strlit_lens` は更新不要**: `@strlit_pool` は不変なので、
  既存の lit_idx → offset の対応関係は GC 後も維持される
- **forwarding table 不要**: slot idx を動かさないので、ルートとヒープ内 obj_id の
  書き換えは発生しない

### Sweep phase (GC-1)

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
    gc_collect          # 必要なら STW GC を起動 (mark + compact + sweep)
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

- **再帰なし** — `gc_drain_mark_stack` / `gc_compact_pools` ともに反復ループで実装
- **bool ローカル変数を分岐に使わない** (rule 11) — すべて条件式直接判定 / Integer カウンタ
- **kind タグは Integer 定数** — `HEAP_KIND_TOMBSTONE = 0` を `HEAP_KIND_*` 群に追加。
  既存の `heap_str?` `heap_array?` は `@heap_kind[idx] == HEAP_KIND_*` で値比較する
  ため、tombstone (= 0) は自然に「いずれの型でもない」と弁別される
- **戻り値の中間変数化** (rule 6) — `alloc_heap_slot` は `result = 0` で初期化、
  if 各分岐で `result = box_heap(...)` 代入、最後に `result` を返す形
- **3 ブランチ if-elsif の対称ループ** — `gc_compact_pools` の `HEAP_KIND_STRING` /
  `HEAP_KIND_ARRAY` / `HEAP_KIND_INSTANCE` の各ブランチで pool 走査ロジックは
  ほぼ同じだが、spinel が `@*_pool` を別 IntArray として識別するため共通ヘルパに
  切り出さず、敢えて重複させている (`gc_drain_mark_stack` と同じ判断)

## デバッグ

`SETSUNARUBY_DUMP_GC=1` を環境変数に設定すると、各 GC 実行時に STDERR へ
1 行統計を吐く:

```
[gc] total=N live=L freed=F str=S arr=A ivar=I threshold=T
```

| 値 | 意味 |
|---|---|
| `total` | `@heap_kind.length` (tombstone 含む slot の物理長) |
| `live` | GC 後の生存 slot 数 |
| `freed` | 今回 sweep で新たに tombstone 化した slot 数 |
| `str` | GC-2 圧縮後の `@str_pool.length` |
| `arr` | GC-2 圧縮後の `@heap_arr_pool.length` |
| `ivar` | GC-2 圧縮後の `@instance_ivar_pool.length` |
| `threshold` | 次回 GC を起動する live 数の閾値 |

`@dump_hir` (`SETSUNARUBY_DUMP_HIR`) と同じパターン。spinel AOT で ENV が解釈
されないビルド構成では常に false 相当。

## 現状の制限と後続

- **slot は前詰めしない** — `@heap_kind.length` 自体は伸びたまま (tombstone を
  freelist で再利用するので「実効サイズ」は頭打ち)。Stage GC-3 (任意) で forwarding
  table 付きの slot compaction を検討
- **JIT 案 C 連携なし** — JIT-4 案 A は機械語ダンプのみで実機実行していない
  (詳細は [jit/status.md](../jit/status.md))。案 C 導入時に safepoint 設計が必要
- **インクリメンタル / 世代別 GC なし** — 現状は STW で `gc_collect` 中ずっと VM が止まる。
  ヒープが大規模になるまでは STW で十分

## 参照箇所 (`lib/setsunaruby/interp.rb`)

- 定数: `HEAP_KIND_TOMBSTONE` 〜 `HEAP_KIND_INSTANCE`
- ivar: `@heap_marked` / `@heap_freelist` / `@gc_mark_stack` / `@gc_threshold` /
  `@dump_gc` / `@strlit_pool`
- メソッド: `gc_collect` / `gc_push_root` / `gc_drain_mark_stack` /
  `gc_compact_pools` / `alloc_heap_slot` / `strlit_to_str_pool`
