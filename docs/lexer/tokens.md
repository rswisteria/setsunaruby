# Lexer 仕様 — トークン

Lexer (`Interp#next_token`) はソース文字列 `@bytes` の先頭から 1 トークンずつ
生成する。中間トークン列を作らず、`@cur_token` に常に 1 件だけ保持する設計
(ストリーミング)。

## Token クラス

`lib/setsunaruby/token.rb` で定義 (トップレベルクラス、spinel の名前空間プレフィックス
処理回避のため)。

```ruby
class Token
  attr_accessor :kind, :int_value, :str_value, :line
end
```

| フィールド | 型 | 用途 |
|---|---|---|
| `kind` | Symbol (`TokenKind::*`) | トークン種別 |
| `int_value` | Integer | kind 別の補助値 (詳細は下表) |
| `str_value` | String | 現状未使用 (将来予約) |
| `line` | Integer | 出現行番号 (1 始まり) |

`int_value` の使われ方は kind ごとに異なる。識別子の名前や文字列リテラルの
内容を **Symbol/String に変換せず Integer 1 つで表現** している点が特徴的
(spinel ルール 11)。

## トークン種別 (TokenKind)

`lib/setsunaruby/token.rb` の `module TokenKind` で定義。

### 値・リテラル

| Kind | 例 | int_value | 備考 |
|---|---|---|---|
| `INT` | `42` | 整数値そのもの | 10 進整数のみ。負号は単項マイナスとして parser 側で扱う |
| `STR` | `"hello\n"` | strlit_idx | 文字列はリテラル idx で参照 (実体は `@str_pool`) |
| `IDENT` | `foo` `bar?` `baz!` | `(start \<\< 16) | len` | `@bytes` 上の (start, len) を pack |
| `IVAR` | `@count` | `(start \<\< 16) | len` | `@` の次のバイトから始まる名前 |

識別子は末尾 `?` / `!` を 1 byte 取り込む (`block_given?`、`destructive!` 等)。
取り込み済みの場合はキーワード判定を skip する (Stage 3c.3)。

### キーワード

| Kind | 表記 | 導入 Stage |
|---|---|---|
| `KW_PUTS` | `puts` | Stage 0 |
| `KW_TRUE` `KW_FALSE` `KW_NIL` | `true` `false` `nil` | Stage 0 |
| `KW_IF` `KW_ELSIF` `KW_ELSE` `KW_END` `KW_THEN` | `if` `elsif` `else` `end` `then` | Stage 1 |
| `KW_WHILE` | `while` | Stage 1 |
| `KW_DEF` `KW_RETURN` | `def` `return` | Stage 2 |
| `KW_DO` | `do` | Stage 3c.1 |
| `KW_YIELD` | `yield` | Stage 3c.2 |
| `KW_CLASS` `KW_SELF` | `class` `self` | Stage 3d.1 |
| `KW_BEGIN` `KW_RESCUE` `KW_ENSURE` `KW_RAISE` | `begin` `rescue` `ensure` `raise` | Stage 3e |
| `KW_SUPER` | `super` | Stage 3d.5 |

キーワードは `read_ident_or_keyword` の `match_keyword` で判定。識別子として
読み込まれた `(start, len)` を `KW_*_BYTES` 定数のバイト列と `match_bytes` で
バイト列比較する。文字リテラル比較を避ける spinel ルール 7 への対応。

### 演算子・区切り

| Kind | 表記 | 用途 |
|---|---|---|
| `PLUS` `MINUS` `STAR` `SLASH` `PERCENT` | `+ - * / %` | 算術 |
| `EQ` | `=` | 代入 |
| `EQ_EQ` `LT` `GT` `LE` `GE` | `== \< \> \<= \>=` | 比較 |
| `NEQ` | `!=` | 不等価 (Stage 4a) |
| `LSHIFT` | `\<\<` | 整数左シフト・文字列追加・配列 push (多態) |
| `SHR` | `\>\>` | 整数右シフト (Stage 4a) |
| `BAND` `BXOR` | `& ^` | 整数 AND / XOR (Stage 4a)。`PIPE` (`\|`) は OR と兼用 |
| `BNOT` | `~` | 整数 NOT (単項、Stage 4a) |
| `LAND` `LOR` | `&& \|\|` | 短絡 AND / OR (Stage 4a) |
| `NOT` | `!` | 否定 (単項、Stage 4a)。識別子末尾の `!` は別途 IDENT 内で処理 |
| `LPAREN` `RPAREN` | `( )` | グルーピング・引数リスト |
| `LBRACK` `RBRACK` | `[ ]` | 配列リテラル・index |
| `LBRACE` `RBRACE` | `{ }` | 中括弧ブロック |
| `DOT` | `.` | メソッド呼び出し |
| `PIPE` | `\|` | ブロックパラメータ区切り / 整数 OR (Stage 4a。文脈で判別) |
| `COMMA` | `,` | 引数・要素区切り |
| `HASH_ROCKET` | `=>` | `rescue Class => e` 用 |

### 制御

| Kind | 用途 |
|---|---|
| `NEWLINE` | 文の終端候補 (parser が `;` 相当として扱う) |
| `EOF` | 入力終端 |

## 字句規則の細部

### 空白とコメント

- `' '` (0x20) と `'\t'` (0x09) は読み飛ばす
- `# 行末まで` は `#` 検出後に改行までスキップ
- `\n` (0x0A) は `NEWLINE` トークンを生成して `@line += 1`

### 数値

`read_number` で連続する 10 進数字 (`0`-`9`) を読み込み、`int_value` に整数を
セットして `INT` を返す。負号は単項マイナスとして parser が扱うため、Lexer は
正数のみ生成する。

### 文字列リテラル

`read_string` で `"..."` を読む。escape: `\n` `\t` `\r` `\\` `\"` `\0` のみ対応。
escape 解決後のバイト列を **`@str_pool` に直接追記**し、`@strlit_starts` /
`@strlit_lens` に新規エントリを追加。Token の `int_value` にそのリテラル idx を入れる。

UTF-8 透過 (escape は 1 バイトずつ処理、それ以外は無加工)。生改行入り文字列リテラルも
許容する (`@line` を更新する)。

### 識別子の packed 表現

```
名前 = @bytes[start ... start + len]
int_value = (start \<\< 16) | len
```

識別子の最大長は 2^16。Symbol を経由しないことで spinel ルール 11 に従う。
名前比較は `bytes_eq` (start/len のペアで `@bytes` 上を直接比較)。

### 演算子の 2 文字対応

`read_punct` 内で先頭バイトと次バイトを 2 文字 lookahead して合成トークンを生成する:

| 先頭 | 次バイト | 結果 | Stage |
|---|---|---|---|
| `=` | `=` | `EQ_EQ` | Stage 0 |
| `=` | `>` | `HASH_ROCKET` | Stage 3e |
| `<` | `=` | `LE` | Stage 0 |
| `<` | `<` | `LSHIFT` | Stage 3a |
| `>` | `=` | `GE` | Stage 0 |
| `>` | `>` | `SHR` | Stage 4a |
| `&` | `&` | `LAND` | Stage 4a |
| `&` | (他) | `BAND` | Stage 4a |
| `\|` | `\|` | `LOR` | Stage 4a |
| `\|` | (他) | `PIPE` | Stage 3c.1 |
| `!` | `=` | `NEQ` | Stage 4a |
| `!` | (他) | `NOT` | Stage 4a |
| `^` | — | `BXOR` | Stage 4a |
| `~` | — | `BNOT` | Stage 4a |

## ストリーミング消費

Parser は次のトークンを `@cur_token` で参照する。Lexer 側に明示的なバッファは
なく、`expect(kind)` 等で `@cur_token` を消費する直前に `next_token` で更新する。
これにより複数トークンの先読みは行わない (LL(1))。
