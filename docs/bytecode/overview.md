# Bytecode 概観 — 値表現・ヒープ・実行状態

setsunaruby の VM は単純なスタックマシン。値はすべてタグ付き Integer で表現し、
ヒープ参照は kind タグ付きの並列 IntArray で管理する。

opcode 一覧は [opcodes.md](opcodes.md)。

## 値表現 (タグ付き即値)

すべての Ruby 値は単一の Integer (obj_id) で表現。CRuby の `VALUE` を踏襲した
タグ付け。

| 値 | obj_id | 判定 |
|---|---|---|
| `nil` | `0` | `== 0` |
| `false` | `2` | `== 2` |
| `true` | `4` | `== 4` |
| Fixnum `n` | `(n \<\< 1) | 1` | 下位 1 bit が 1 (`v & 1 == 1`) |
| ヒープ参照 | `(idx \<\< 3) | 0b110` | 下位 3 bit が `0b110` (`v & 7 == 6`) |
| Symbol `:foo` | `sym_id \<\< 3` (sym_id ≥ 1) | `v != 0 && (v & 7) == 0` (Stage 4c) |

- `nil` / `false` / `true` は `lib/setsunaruby/object.rb` で `NIL_VAL` / `FALSE_VAL` /
  `TRUE_VAL` 定数として定義
- Fixnum 範囲は LSB を 1 で潰すため Ruby の通常 Integer 範囲より 1 bit 狭い
- `truthy?` 判定: `v != NIL_VAL && v != FALSE_VAL` (0 含むそれ以外は真)
- Symbol は intern table (`@sym_name_starts` / `@sym_name_lens` の並列 IntArray) を
  別途持ち、ヒープには載らない (`@heap_kind` の管理外)。詳細は
  [opcodes.md](opcodes.md) の `PUSH_SYM` を参照

## ヒープオブジェクト

`(idx \<\< 3) | 0b110` で参照される。実体は kind タグで区別された並列 IntArray の
スロット 1 つ分。

### ヒープ表 (並列 IntArray)

| ivar | 内容 |
|---|---|
| `@heap_kind[idx]` | 0=tombstone (GC-1), 1=String, 2=Array, 3=Instance |
| `@heap_starts[idx]` | kind 別 pool への offset |
| `@heap_lens[idx]` | バイト数 (String) / 要素数 (Array) / ivar 個数 (Instance) |
| `@heap_instance_class[idx]` | class_idx (-1 = 非インスタンス) |
| `@heap_marked[idx]` | GC-1 の mark 用ビット (0=未 mark, 1=live) |

### kind 別ストレージ

| kind | pool | 1 要素 |
|---|---|---|
| 1 = String | `@str_pool` | バイト (Integer 0..255)。GC-2 で圧縮対象 |
| 2 = Array | `@heap_arr_pool` | 任意の obj_id。GC-2 で圧縮対象 |
| 3 = Instance | `@instance_ivar_pool` | ivar 値 (任意の obj_id)。GC-2 で圧縮対象 |

文字列リテラルのバイトは `@strlit_pool` (lex 時に確定する不変領域) に格納され、
heap String の `@str_pool` とは独立に管理される。`@strlit_pool` は GC 対象外なので、
`@strlit_starts` / `@strlit_lens` の offset は GC を跨いで安定する。

### 確保ヘルパ

`alloc_heap_slot(kind, start, len, class_idx)` が `@heap_kind` / `@heap_starts` /
`@heap_lens` / `@heap_instance_class` / `@heap_marked` の 5 並列 IntArray の更新を
1 操作にまとめる。GC-1 以降は live slot 数が `@gc_threshold` を超えたらこの中で
`gc_collect` を起動し、`@heap_freelist` に idx があれば再利用する。詳細は
[gc/overview.md](../gc/overview.md)。

## VM の実行状態

### スタック

| ivar | 内容 |
|---|---|
| `@stack` | 値スタック (`Array<Integer>`) |
| `@pc` | プログラムカウンタ (`@bytecode` 上の byte 位置) |

### ローカル変数

| ivar | 内容 |
|---|---|
| `@locals` | 全フレームのローカル変数を flat に保持 |
| `@cur_base` | 現フレームの先頭 (= `@locals` の base 相対アクセス) |
| `@cur_self` | 現フレームの receiver (`self` 値) |

`LOAD_LOCAL idx` / `STORE_LOCAL idx` は `@locals[@cur_base + idx]` を読み書き。

### コールフレーム (並列 IntArray)

| ivar | 内容 |
|---|---|
| `@cfp_pcs` | 戻り先 PC |
| `@cfp_bases` | 戻り先 `@cur_base` |
| `@cfp_selfs` | 戻り先 `@cur_self` |
| `@cfp_block_pcs` | ブロック先頭 PC (-1 = ブロックなし) |
| `@cfp_block_arities` | ブロックの param 数 |
| `@cfp_method_idx` | 現フレームで実行中の method idx (super 用) |
| `@cfp_caller_lexical_method` | yield の lexical method tracking 用 (Stage 3d.5) |

push/pop は対称的に行われる (`push_call_frame` / `pop_call_frame`)。

### yield 退避スタック

| ivar | 内容 |
|---|---|
| `@yield_pcs` | YIELD で `@pc` を退避 |
| `@yield_bases` | YIELD で `@cur_base` を退避 |
| `@yield_target_idx` | yield が向かう lexical method の cfp idx |

### 例外ハンドラスタック (Stage 3e)

| ivar | 内容 |
|---|---|
| `@exception` | 現在伝播中の例外 (NIL_VAL = なし) |
| `@handler_catch_pcs` | rescue 節の先頭 PC |
| `@handler_ensure_pcs` | ensure 節の先頭 PC (-1 = なし) |
| `@handler_stack_depths` | PUSH_HANDLER 時の `@stack.length` |
| `@handler_cfp_depths` | PUSH_HANDLER 時の `@cfp_pcs.length` |
| `@handler_yield_depths` | PUSH_HANDLER 時の `@yield_pcs.length` |

RAISE 時はハンドラスタック top から上記 depth まで `@stack` / `@cfp_*` /
`@yield_*` を巻き戻して `@pc = catch_pc` に飛ぶ。

## メソッド表 (並列 IntArray)

| ivar | 内容 |
|---|---|
| `@method_name_starts` / `@method_name_lens` | name の `@bytes` 上の (start, len) |
| `@method_pcs` | bytecode 内の method 先頭 PC |
| `@method_arities` | パラメータ数 |
| `@method_local_counts` | スコープのローカル変数総数 |
| `@method_class_idx` | 所属 class_idx (-1 = トップレベル) |
| `@method_body_ends` | bytecode 内の method 末尾 PC (JIT-2 で導入) |
| `@jit_call_counts` | 呼び出し回数カウンタ (JIT-1) |

## クラス表 (並列 IntArray)

| ivar | 内容 |
|---|---|
| `@class_name_starts` / `@class_name_lens` | クラス名 packed |
| `@class_method_starts` / `@class_method_counts` | `@method_*` 上のスライス |
| `@class_ivar_starts` / `@class_ivar_counts` | ivar 名表 (`@class_ivar_name_*`) のスライス |
| `@class_ivar_name_starts` / `@class_ivar_name_lens` | flat ivar 名 packed |
| `@class_parent_idx` | 親 class_idx (-1 = なし) |

builtin class (Integer / Array / String / StandardError) は class table の先頭に
匿名で pre-register される。`@bytes` の先頭に builtin 名のバイト列を prepend し、
`@method_name_starts` で prefix 内の offset を指す。

## バイトコードのレイアウト

`@bytecode` は単一の Integer 配列で、トップレベル → メソッド本体 → ブロック本体
の順に追記される (skip-jump パターン)。

```
+--- top-level execution ---+
|                           |
|   ...                     |
|   JUMP skip_method        |
|   method1_pc:             |
|     <method1 body>        |
|     RETURN                |
|   skip_method:            |
|   ...                     |
|   JUMP skip_block         |
|   block1_pc:              |
|     <block1 body>         |
|     BLOCK_RETURN          |
|   skip_block:             |
|   ...                     |
|   HALT                    |
+---------------------------+
```

トップレベル末尾には `HALT` が emit される。
