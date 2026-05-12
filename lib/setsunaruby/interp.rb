require_relative 'token'
require_relative 'ast'
require_relative 'opcodes'
require_relative 'hir_opcodes'
require_relative 'lir_opcodes'
require_relative 'object'

module Setsunaruby
  # Lexer / Parser / Compiler / VM を統合した1パス実行器。
  #
  # Stage 1 で追加: ローカル変数 + 制御構造 (if/while)。
  # 中間配列の保持を避けるストリーミング処理は維持し、コンパイル時に
  # ローカル変数名 (Symbol) を @local_names IntArray (sp_sym 配列) に
  # 蓄積する。VM 実行時は @locals IntArray (obj_id) を slot 番号でアクセス。
  class Interp
    # JIT-1 (ZJIT 風プロファイル収集): メソッドごとの呼び出し回数が
    # JIT_HOT_THRESHOLD ちょうどに達した時点で 1 度だけホット検出ログを出す。
    JIT_HOT_THRESHOLD = 100

    # ---- ASCII コード定数 (Lexer 用) ----
    NL    = 10
    TAB   =  9
    CR_B  = 13       # '\r'
    NUL_B = 0        # '\0'
    SP    = 32
    DQUOTE_B  = 34   # '"'
    HASH  = 35
    LP    = 40
    RP    = 41
    STAR_BYTE  = 42
    PLUS_BYTE  = 43
    COMMA_BYTE = 44
    MINUS_BYTE = 45
    DOT_BYTE   = 46  # '.' (Stage 3b)
    SLASH_BYTE = 47
    LBRACK_B   = 91  # '[' (Stage 3b)
    RBRACK_B   = 93  # ']' (Stage 3b)
    LBRACE_B   = 123 # '{' (Stage 3c.3 中括弧ブロック)
    RBRACE_B   = 125 # '}'
    PIPE_B     = 124 # '|' (Stage 3c.1 ブロックパラメータ、Stage 4a 整数 OR)
    Q_MARK_B   = 63  # '?' (Stage 3c.3 識別子末尾)
    BANG_B     = 33  # '!' (Stage 3c.3 識別子末尾、Stage 4a 否定 / 不等価先頭)
    AMP_B      = 38  # '&' (Stage 4a 整数 AND / `&&`)
    CARET_B    = 94  # '^' (Stage 4a 整数 XOR)
    TILDE_B    = 126 # '~' (Stage 4a 整数 NOT)
    AT_B       = 64  # '@' (Stage 3d.1 インスタンス変数)
    PCT   = 37
    EQ    = 61
    LT_BYTE = 60
    GT_BYTE = 62
    UND   = 95
    BSLASH_B = 92    # '\\'
    D0    = 48
    D9    = 57
    A_LC  = 97
    Z_LC  = 122
    A_UC  = 65
    Z_UC  = 90
    # 文字列エスケープの後続バイト (`\n` `\t` `\r` `\0` `\\` `\"`)。
    ESC_N_B    = 110   # 'n'
    ESC_T_B    = 116   # 't'
    ESC_R_B    = 114   # 'r'
    ESC_ZERO_B = 48    # '0' (= D0 と同値だが意図を分離)
    # ヒープオブジェクト obj_id の下位 3 bit タグ。Stage 0 で予約した (idx<<3)|0b110。
    HEAP_TAG = 6
    # ヒープオブジェクトの kind (= @heap_kind の値)。Stage 3b 以降は要素を増やしていく。
    # 0 は GC-1 の tombstone (sweep で free list 化された slot のマーカ)。
    # alloc_heap_slot は必ず 1..3 のいずれかを書き込むので、@heap_kind[idx] == 0 が
    # 「GC が解放した slot」を弁別する条件になる。
    HEAP_KIND_TOMBSTONE = 0   # GC-1: sweep で tombstone 化された slot
    HEAP_KIND_STRING    = 1
    HEAP_KIND_ARRAY     = 2
    HEAP_KIND_INSTANCE  = 3   # Stage 3d.1: ユーザ定義クラスのインスタンス

    # Stage 3d.3: builtin class を class table の先頭 3 スロットに pre-register する。
    # Fixnum / Array / String が `obj.method(args)` でメソッドディスパッチを受けるとき、
    # class_of_value が以下の class_idx にマップする。これにより Array#length のような
    # builtin メソッドを通常の class table 経由で resolve できるようになり、user 定義の
    # 同名メソッドが衝突せず class_idx で区別される。
    BUILTIN_CLASS_INTEGER = 0
    BUILTIN_CLASS_ARRAY   = 1
    BUILTIN_CLASS_STRING  = 2
    BUILTIN_CLASS_COUNT   = 3
    # Stage 3e: StandardError は名前付きで pre-register され (BUILTIN_CLASS_COUNT loop の外で
    # declare_class)、idx は BUILTIN_CLASS_COUNT (= 3) に固定される。`raise "msg"` の文字列
    # 自動ラップと、user-defined error class の親 lookup の両方で参照する。
    BUILTIN_CLASS_STDERR  = 3

    # Stage 3e: @bytes prefix のレイアウト。register_builtin_classes_and_methods が
    # 各 builtin method 名/クラス名/ivar 名を ここに置かれた byte 列として参照する。
    # ユーザコードはこの prefix の直後から始まる (init_bytes_with_builtin_prefix が @lex_pos を
    # PREFIX_TOTAL_LEN にセットする)。
    PREFIX_LENGTH_OFFSET   = 0                                                # "length"
    PREFIX_STDERR_OFFSET   = PREFIX_LENGTH_OFFSET + 6                         # "StandardError"
    PREFIX_MESSAGE_OFFSET  = PREFIX_STDERR_OFFSET + 13                        # "message"
    PREFIX_INIT_OFFSET     = PREFIX_MESSAGE_OFFSET + 7                        # "initialize"
    PREFIX_EACH_OFFSET     = PREFIX_INIT_OFFSET + 10                          # "each" (Stage 3d.5)
    PREFIX_MAP_OFFSET      = PREFIX_EACH_OFFSET + 4                           # "map"
    PREFIX_TIMES_OFFSET    = PREFIX_MAP_OFFSET + 3                            # "times"
    PREFIX_TOTAL_LEN       = PREFIX_TIMES_OFFSET + 5

    # キーワードバイト列。spinel の sp_String / const char* 不整合を避けるため
    # 文字列ではなくバイト配列で直接比較する。
    KW_PUTS_BYTES  = [112, 117, 116, 115].freeze              # "puts"
    KW_TRUE_BYTES  = [116, 114, 117, 101].freeze              # "true"
    KW_FALSE_BYTES = [102, 97, 108, 115, 101].freeze          # "false"
    KW_NIL_BYTES   = [110, 105, 108].freeze                   # "nil"
    KW_IF_BYTES    = [105, 102].freeze                        # "if"
    KW_ELSIF_BYTES = [101, 108, 115, 105, 102].freeze         # "elsif"
    KW_ELSE_BYTES  = [101, 108, 115, 101].freeze              # "else"
    KW_END_BYTES   = [101, 110, 100].freeze                   # "end"
    KW_WHILE_BYTES  = [119, 104, 105, 108, 101].freeze        # "while"
    KW_THEN_BYTES   = [116, 104, 101, 110].freeze             # "then"
    KW_DEF_BYTES    = [100, 101, 102].freeze                  # "def"
    KW_RETURN_BYTES = [114, 101, 116, 117, 114, 110].freeze   # "return"
    KW_DO_BYTES     = [100, 111].freeze                       # "do" (Stage 3c.1)
    KW_YIELD_BYTES  = [121, 105, 101, 108, 100].freeze        # "yield" (Stage 3c.2)
    KW_CLASS_BYTES  = [99, 108, 97, 115, 115].freeze          # "class" (Stage 3d.1)
    KW_SELF_BYTES   = [115, 101, 108, 102].freeze             # "self" (Stage 3d.1)
    KW_NEW_BYTES    = [110, 101, 119].freeze                  # "new" (Stage 3d.1: ClassName.new 専用認識)
    KW_INITIALIZE_BYTES = [105, 110, 105, 116, 105, 97, 108, 105, 122, 101].freeze   # "initialize" (Stage 3d.2)
    # Stage 3b/3c: ドット method 名 (現状 length / each / times / map をサポート)。
    # 将来 method_name_is_*? を増やすときも同じ場所に追加する。
    KW_LENGTH_BYTES = [108, 101, 110, 103, 116, 104].freeze   # "length"
    KW_EACH_BYTES   = [101, 97, 99, 104].freeze               # "each"
    KW_TIMES_BYTES  = [116, 105, 109, 101, 115].freeze        # "times"
    KW_MAP_BYTES    = [109, 97, 112].freeze                   # "map" (Stage 3c.3)
    # Stage 3c.3: block_given? は識別子として lex され、compile 時に名前判定する。
    KW_BLOCK_GIVEN_BYTES = [98, 108, 111, 99, 107, 95, 103, 105, 118, 101, 110, 63].freeze   # "block_given?"
    # Stage 3e: 例外処理キーワード。
    KW_BEGIN_BYTES   = [98, 101, 103, 105, 110].freeze            # "begin"
    KW_RESCUE_BYTES  = [114, 101, 115, 99, 117, 101].freeze       # "rescue"
    KW_ENSURE_BYTES  = [101, 110, 115, 117, 114, 101].freeze      # "ensure"
    KW_RAISE_BYTES   = [114, 97, 105, 115, 101].freeze            # "raise"
    KW_SUPER_BYTES   = [115, 117, 112, 101, 114].freeze           # "super" (Stage 3d.5)
    # Stage 4b: 無限ループとループ制御。
    KW_LOOP_BYTES    = [108, 111, 111, 112].freeze                # "loop"
    KW_BREAK_BYTES   = [98, 114, 101, 97, 107].freeze             # "break"
    KW_NEXT_BYTES    = [110, 101, 120, 116].freeze                # "next"
    KW_MESSAGE_BYTES = [109, 101, 115, 115, 97, 103, 101].freeze  # "message"
    KW_STDERR_BYTES  = [83, 116, 97, 110, 100, 97, 114, 100, 69, 114, 114, 111, 114].freeze   # "StandardError"

    def initialize
      @src       = ""
      @bytes     = []
      @lex_pos   = 0
      @line      = 1
      @cur_token = nil
      @bytecode  = []           # IntArray
      @stack     = []           # IntArray
      @pc        = 0
      @locals    = []           # IntArray (obj_id を slot 番号でアクセス)
      # ローカル変数名は「@bytes 上のバイト範囲」で識別する (Symbol 不使用)。
      # 同じ名前の変数は同じ slot を共有する。
      # spinel に Symbol/sp_sym を扱わせると Token フィールドの型推論が崩壊する
      # ため、すべて mrb_int (start_pos / length) のみで表現する。
      @local_starts = []        # IntArray (各 slot の名前の start_pos)
      @local_lens   = []        # IntArray (各 slot の名前の length)
      # @scope_base 以降の @local_starts/@local_lens が現在のスコープ。
      # トップレベルは 0、method 内コンパイル時のみ前進する。
      # @scope_base だけでは method 内か判定できない (トップレベルにローカル
      # 変数 0 個の状態で def に入ると @scope_base = 0 のまま) ため、
      # @in_method フラグも併用する。
      @scope_base  = 0
      @in_method   = false
      # メソッドテーブル (並列 IntArray、spinel ルール 3 遵守)。
      @method_name_starts  = []   # IntArray (メソッド名の start_pos)
      @method_name_lens    = []   # IntArray (メソッド名の length)
      @method_pcs          = []   # IntArray (本体の開始 PC)
      @method_arities      = []   # IntArray (パラメータ数)
      @method_local_counts = []   # IntArray (パラメータ含むローカル変数の総数)
      @method_body_ends    = []   # IntArray (JIT-2: メソッド本体終了 PC、HIR 構築の範囲決定用)
      @jit_call_counts     = []   # IntArray (JIT-1: メソッド呼び出し回数)
      # JIT-4c: 実機実行用に保持する関数ポインタとそのページサイズ。
      # @jit_fn_addrs[m_idx] = 0  → 未試行、 -1 → 試したが install 失敗 (再試行しない)、
      #                       > 0 → mmap 済みの実行可能 buffer 先頭アドレス。
      # SETSUNARUBY_JIT=1 + (JIT::ARCH_ARM64 または ENV 経由の override) でのみ install。
      @jit_fn_addrs        = []   # IntArray
      @jit_fn_sizes        = []   # IntArray (free 時の munmap サイズ)
      # JIT-2: HIR (lite SSA) を SoA で保持。build_and_dump_hir が再構築する。
      @hir_kind      = []   # IntArray (HirOp 定数)
      @hir_op0       = []   # IntArray (kind ごとの 1 番目のオペランド)
      @hir_op1       = []   # IntArray
      @hir_op2       = []   # IntArray
      @hir_call_args = []   # IntArray (CALL の引数 hir_id を flat に並べる)
      @hir_deleted   = []   # IntArray (JIT-3: 0=alive, 1=dead。eliminate_dead_code が mark)
      # JIT-3b: basic block 構造 (CFG)。pass_build_cfg が構築する。
      @hir_bb        = []   # IntArray (各 hir_id の所属 BB id)
      @bb_first_insn = []   # IntArray (各 BB の最初の hir_id)
      @bb_last_insn  = []   # IntArray (各 BB の最後の hir_id)
      @bb_succ0      = []   # IntArray (JUMP_IF_FALSE の jump target / JUMP の target / フォールスルー)
      @bb_succ1      = []   # IntArray (JUMP_IF_FALSE の fallthrough、それ以外は -1)
      # JIT-3b2: dominator tree + dominance frontier (CFG 分析、phi 配置の前提)。
      @bb_idom       = []   # IntArray (各 BB の immediate dominator BB id、root は自分)
      @bb_df_starts  = []   # IntArray (各 BB の DF chunk の開始 offset)
      @bb_df_counts  = []   # IntArray (各 BB の DF サイズ)
      @bb_df_flat    = []   # IntArray (DF の BB id を flat に並べる)
      # CFG 構築直後に build_preds_table が一度だけ書き込み、dominator/DF/将来の
      # phi 挿入の各パスから読み出す。
      @bb_preds_starts = []
      @bb_preds_counts = []
      @bb_preds_flat   = []
      # dom_intersect が呼ぶたびに毎回 nbb 個の配列を確保すると spinel の型推論
      # にも allocator にも厳しいので、scratch IntArray として共有する。
      @dom_visited     = []
      # dominator tree の child リスト (rename DFS で使う)
      @bb_dom_children_starts = []
      @bb_dom_children_counts = []
      @bb_dom_children_flat   = []
      # JIT-3b3: phi の引数 (= 各 pred 経由での値)。preds 順に並ぶ value hir_id。
      @hir_phi_args  = []
      # rename で hir_id をリダイレクトするマップ。LOAD_LOCAL を消すために、
      # その hir_id を「reaching def の hir_id」に向ける。最後に apply_rename_targets で
      # 全 use を置換する。
      @hir_rename_target = []
      # JIT-3c: 型プロファイルと特化用の bc_pc 逆引き。
      # @profile_fixnum_pc[bc_pc] = 1 ならその PC の算術/比較が一度でも Fixnum で
      # 実行された (= 特化候補)。@hir_bc_pc[hir_id] = その insn の出処 bytecode PC
      # (-1 = bytecode 由来でない: LoadParam / Phi / GuardFixnum 等)。
      @profile_fixnum_pc = []
      @hir_bc_pc         = []
      # JIT-4 (案 A): LIR (Low-level IR) を SoA で保持。pass_lower_to_lir が構築し、
      # pass_encode_arm64 が @lir_machine_code に 32bit 機械語を生成する。
      # 実機実行はせず、ダンプのみ。
      @lir_kind         = []
      @lir_op0          = []
      @lir_op1          = []
      @lir_op2          = []
      @lir_bb           = []
      @lir_machine_code = []
      # JIT-4c x86_64: 可変長命令の byte 並びと、各 LIR insn の機械語先頭 byte offset。
      # pass_encode_x86_64 が build。arm64 は @lir_machine_code (固定 4 byte word) を使う。
      @lir_byte_offset  = []
      @jit_bytes        = []
      # spinel AOT で ENV が解釈されない場合は常に false 相当 (HIR ダンプは CRuby のみ)。
      @dump_hir      = ENV["SETSUNARUBY_DUMP_HIR"] == "1"
      # JIT-4c: 実機実行を有効化するゲート。SETSUNARUBY_JIT=1 で ON。デフォルト OFF
      # の理由は、(1) 既存テストの観測挙動を変えないため、(2) x86_64 ホストで arm64
      # 機械語を呼ぶと即 SIGSEGV する (現状 arm64 emitter しか持たないため) 防衛策。
      # AOT バイナリで JIT::ARCH_ARM64 が false な環境では install を skip する。
      # `defined?(JIT)` は spinel では常に "expression" (truthy) を返すので AOT では
       # ENV だけが効く。CRuby は JIT module を持たないため nil/false 扱いになり、
       # SETSUNARUBY_JIT=1 を設定しても自動的に install/dispatch がスキップされる。
      @jit_exec_enabled = (ENV["SETSUNARUBY_JIT"] == "1") && (defined?(JIT) ? true : false)
      # VM のコールフレームスタック (並列 IntArray)。
      # locals の縮小は @cur_base で行うので length 自体は記録しない。
      @cfp_pcs   = []   # IntArray (戻り PC)
      @cfp_bases = []   # IntArray (戻り後の @cur_base)
      # Stage 3d.5: 各 cfp フレームが呼ばれた時点で active だった lexical method の cfp idx を退避。
      # YIELD でブロックに入ったとき、そのブロックの lexical method は「呼び出し元の lexical method」
      # = この値。yield 時に @yield_target_idx に積み上げる用。-1 は top-level (method 外)。
      @cfp_caller_lexical_method = []
      # Stage 3d.5: 現在実行中の method の m_idx (super で defining class を取るため)。
      # 並列 IntArray の 1 つ。-1 は top-level (method 外、super 不可)。
      @cfp_method_idx = []
      @cur_base  = 0    # 現在実行中の locals base
      # Stage 3c.2: コールフレームに紐付くブロック PC (-1 = ブロックなし)。
      # YIELD は @cfp_block_pcs.last を読んでブロックへ飛ぶ。
      # @cfp_block_arities は yield argc とブロック param 数の不一致をランタイムで弾くため。
      @cfp_block_pcs     = []
      @cfp_block_arities = []
      # Stage 3c.2: yield 中の block 本体実行のための保存スタック。
      # YIELD で push、BLOCK_RETURN で pop して @pc / @cur_base を復元する。
      # @cfp_* と独立: 1 つの method 呼び出しの間に複数回 yield する想定。
      @yield_pcs   = []
      @yield_bases = []
      # Stage 3d.5: 「現在の lexical method の cfp idx」スタック。push_call_frame と YIELD の
      # 両方で push し、pop_call_frame と BLOCK_RETURN で pop する。yield は top の値を見て
      # cfp_block_pcs[idx] を target とする (cfp.last ではない)。これにより
      # `def collect; arr.each do; yield; end; end` の yield が arr.each ではなく collect の
      # ブロックを呼べる。-1 は top-level (method 外で yield → LocalJumpError)。
      @yield_target_idx = []
      # Stage 3a/3b: ヒープオブジェクト。obj_id = (idx << 3) | HEAP_TAG。
      # @heap_kind が 1=String, 2=Array を区別する (HEAP_KIND_STRING / HEAP_KIND_ARRAY)。
      # @heap_starts/lens の解釈は kind に依存:
      #   - String: @str_pool への byte offset / length
      #   - Array:  @heap_arr_pool への element offset / length
      # GC はないので idx は単調増加 (削除なし)。
      @heap_kind   = []
      @heap_starts = []
      @heap_lens   = []
      # Stage 3a / GC-2: 文字列バイトプールを 2 系統に分離。
      # @str_pool は heap String slot 専用 (GC で前詰めされる)。
      # @strlit_pool は lex 時に確定する不変リテラル領域で GC 対象外。
      # @strlit_starts / @strlit_lens は @strlit_pool 上の offset / length を保持し、
      # @str_pool 圧縮の影響を受けない。
      @str_pool      = []
      @strlit_pool   = []
      @strlit_starts = []
      @strlit_lens   = []
      # Stage 3b: 配列要素プール (要素は obj_id = tagged value)。
      @heap_arr_pool = []
      # Stage 3d.1: ユーザ定義クラスとインスタンス状態。
      # クラス表 (parallel IntArray):
      @class_name_starts   = []   # クラス名 packed の start (= @bytes 上の offset)
      @class_name_lens     = []
      @class_method_starts = []   # @method_*  上のこのクラスのメソッド開始 idx
      @class_method_counts = []
      @class_ivar_starts   = []   # @class_ivar_name_* 上のこのクラスの ivar 開始 idx
      @class_ivar_counts   = []
      # Stage 3d.4: 親クラスの class_idx (-1 = 親なし、Object 相当)。
      # method dispatch / ivar slot lookup は parent chain を walk する。
      @class_parent_idx    = []
      # クラスごとの ivar 名 packed テーブル (flat、@class_ivar_starts/_counts でスライス)。
      @class_ivar_name_starts = []
      @class_ivar_name_lens   = []
      # 既存 @method_* に並列の class_idx (-1 = トップレベル method)。
      @method_class_idx = []
      # インスタンス状態:
      # @heap_kind[idx] == HEAP_KIND_INSTANCE のとき、@heap_instance_class[idx] が class idx、
      # @heap_starts[idx] が @instance_ivar_pool 上の slot 開始 offset、@heap_lens[idx] が ivar 数。
      @heap_instance_class = []
      @instance_ivar_pool  = []   # 各インスタンスの ivar 値 (obj_id) を flat に並べる
      # コンパイル中の class context (-1 = トップレベル)。
      @cur_class = -1
      # コールフレームに紐付く self (NIL_VAL = self なし、トップレベル相当)。
      @cfp_selfs = []
      @cur_self  = ObjectVal::NIL_VAL
      # Stage 3e: 例外処理。
      # @exception は現在伝播中の例外オブジェクト (NIL_VAL = なし)。RAISE が値を入れて unwind し、
      # rescue で CLEAR_EXCEPTION することでハンドル済みにする。RERAISE_OR_END は ensure 末尾で
      # まだ NIL_VAL でなければ再 unwind する。
      @exception = ObjectVal::NIL_VAL
      # ハンドラスタック (parallel IntArray)。PUSH_HANDLER/POP_HANDLER で push/pop する。
      # 各エントリは catch_pc / 当時の stack 深さ / cfp 深さ / yield 深さ を記録し、
      # RAISE で unwind する際これらを使って状態を巻き戻す。ensure は catch_pc 経由で
      # rescue chain を fall-through するか success path の JUMP で到達するので、handler に
      # ensure_pc を別途持たせる必要はない (rescue なしの begin は catch_pc = ensure 先頭にする)。
      @handler_catch_pcs    = []
      @handler_stack_depths = []
      @handler_cfp_depths   = []
      @handler_yield_depths = []
      # Stage GC-1: STW Mark-Sweep の状態。
      # @heap_marked    : @heap_kind と並列の mark bit (0=未 mark / 1=live)
      # @heap_freelist  : sweep で tombstone 化された slot idx を貯めるスタック
      # @gc_mark_stack  : mark phase の explicit stack (再帰回避、深さは heap 全 slot 分)
      # @gc_threshold   : 次回 GC を起動する live slot 数閾値。GC 後に live * 2 で更新
      # @dump_gc        : SETSUNARUBY_DUMP_GC=1 で各 GC 実行時に STDERR へ統計を吐く
      @heap_marked    = []
      @heap_freelist  = []
      @gc_mark_stack  = []
      @gc_threshold   = 1024
      @dump_gc        = ENV["SETSUNARUBY_DUMP_GC"] == "1"
    end

    def run_file(path)
      run_string(File.read(path))
    end

    def run_string(src)
      @src          = src
      # Stage 3d.3: builtin method 名 (= "length" など) のバイト列を @bytes 先頭に
      # prepend する。lex_pos はこの prefix 後ろから開始するので、lexer は user source
      # しか走査しない。@method_name_starts は prefix 内の offset を指すことで、
      # find_method_in_class の bytes_eq が user source 側の同名識別子と正しく match する。
      init_bytes_with_builtin_prefix(src)
      @line         = 1
      @bytecode     = []
      @stack        = []
      @pc           = 0
      @local_starts = []
      @local_lens   = []
      @scope_base   = 0
      @in_method    = false
      @method_name_starts  = []
      @method_name_lens    = []
      @method_pcs          = []
      @method_arities      = []
      @method_local_counts = []
      @method_body_ends    = []
      @jit_call_counts     = []
      @jit_fn_addrs        = []
      @jit_fn_sizes        = []
      @hir_kind      = []
      @hir_op0       = []
      @hir_op1       = []
      @hir_op2       = []
      @hir_call_args = []
      @hir_deleted   = []
      @hir_bb        = []
      @bb_first_insn = []
      @bb_last_insn  = []
      @bb_succ0      = []
      @bb_succ1      = []
      @bb_idom       = []
      @bb_df_starts  = []
      @bb_df_counts  = []
      @bb_df_flat    = []
      @bb_preds_starts = []
      @bb_preds_counts = []
      @bb_preds_flat   = []
      @dom_visited     = []
      @bb_dom_children_starts = []
      @bb_dom_children_counts = []
      @bb_dom_children_flat   = []
      @hir_phi_args      = []
      @hir_rename_target = []
      @hir_bc_pc         = []
      @lir_kind          = []
      @lir_op0           = []
      @lir_op1           = []
      @lir_op2           = []
      @lir_bb            = []
      @lir_machine_code  = []
      @lir_byte_offset   = []
      @jit_bytes         = []
      # @profile_fixnum_pc は bytecode コンパイル完了後に length 分一括確保するため、
      # 冒頭リセットには含めない (= run_string 後半で `[] + push` 経由で初期化)。
      @dump_hir      = ENV["SETSUNARUBY_DUMP_HIR"] == "1"
      # `defined?(JIT)` は spinel では常に "expression" (truthy) を返すので AOT では
       # ENV だけが効く。CRuby は JIT module を持たないため nil/false 扱いになり、
       # SETSUNARUBY_JIT=1 を設定しても自動的に install/dispatch がスキップされる。
      @jit_exec_enabled = (ENV["SETSUNARUBY_JIT"] == "1") && (defined?(JIT) ? true : false)
      @cfp_pcs   = []
      @cfp_bases = []
      @cur_base  = 0
      @cfp_block_pcs     = []
      @cfp_block_arities = []
      @yield_pcs         = []
      @yield_bases       = []
      @cfp_caller_lexical_method = []
      @cfp_method_idx    = []
      @yield_target_idx  = []
      # Stage 3a/3b: ヒープ状態のリセット。
      @heap_kind     = []
      @heap_starts   = []
      @heap_lens     = []
      @str_pool      = []
      @strlit_pool   = []
      @strlit_starts = []
      @strlit_lens   = []
      @heap_arr_pool = []
      @class_name_starts   = []
      @class_name_lens     = []
      @class_method_starts = []
      @class_method_counts = []
      @class_ivar_starts   = []
      @class_ivar_counts   = []
      @class_parent_idx    = []
      @class_ivar_name_starts = []
      @class_ivar_name_lens   = []
      @method_class_idx       = []
      @heap_instance_class    = []
      @instance_ivar_pool     = []
      @cur_class = -1
      @cfp_selfs = []
      @cur_self  = ObjectVal::NIL_VAL
      # Stage 3e: 例外処理用の VM 状態を run_string ごとにリセット。
      @exception            = ObjectVal::NIL_VAL
      @handler_catch_pcs    = []
      @handler_stack_depths = []
      @handler_cfp_depths   = []
      @handler_yield_depths = []
      # Stage GC-1: GC 状態のリセット。
      @heap_marked    = []
      @heap_freelist  = []
      @gc_mark_stack  = []
      @gc_threshold   = 1024
      @dump_gc        = ENV["SETSUNARUBY_DUMP_GC"] == "1"
      # コンパイル中の method idx (-1 = method 外)。raise/begin を含む method を JIT skip 扱いに
      # するため、compile_raise / compile_begin_rescue がこの idx を見て jit_call_counts を
      # 即 threshold に上げる。
      @cur_method_idx_for_jit = -1
      # break / next の jump 解決スタック (並列 IntArray、spinel ルール 3)。
      # @loop_start_pcs の末尾 = 最内側 loop の cond 再評価位置 (next の jump target)。
      # @break_patch_starts の末尾 = 最内側 loop の break 用 placeholder の開始 idx (in @break_patch_pcs)。
      # @break_patch_pcs はすべての loop の break placeholder PC を flat に並べ、loop 退出時に
      # 当該レンジを current PC へ patch up する。
      # @loop_scope_barriers は compile_inline_block / compile_method_def 進入時の @loop_start_pcs.length
      # を退避し、ブロック / メソッド境界をまたいで break/next が外側 loop に漏れないようにする。
      @loop_start_pcs       = []
      @break_patch_starts   = []
      @break_patch_pcs      = []
      @loop_scope_barriers  = []

      register_builtin_classes_and_methods

      @cur_token = next_token
      while !at_end?
        skip_newlines
        if at_end?
          break
        end
        stmt = parse_statement
        consume_terminator
        compile_stmt(stmt)
        @bytecode.push(Op::POP)
      end
      @bytecode.push(Op::HALT)

      # JIT-3c: 型プロファイル配列を bytecode 全長分 0 で確保。VM の exec_arith /
      # exec_compare が `@profile_fixnum_pc[bc_pc] = 1` で観測フラグを立てる。
      @profile_fixnum_pc = []
      i = 0
      while i < @bytecode.length
        @profile_fixnum_pc.push(0)
        i += 1
      end

      # @locals を local 数分 NIL_VAL で初期化
      @locals = []
      i = 0
      while i < @local_starts.length
        @locals.push(ObjectVal::NIL_VAL)
        i += 1
      end

      run_vm
      nil
    end

    # ============================================================
    # Lexer (1トークンずつ返す)
    # ============================================================

    def next_token
      while @lex_pos < @bytes.length
        b = @bytes[@lex_pos]
        if b == SP || b == TAB
          @lex_pos += 1
        elsif b == NL
          tok = Token.new(TokenKind::NEWLINE, 0, "", @line)
          @line += 1
          @lex_pos += 1
          return tok
        elsif b == HASH
          @lex_pos += 1
          while @lex_pos < @bytes.length && @bytes[@lex_pos] != NL
            @lex_pos += 1
          end
        elsif b == DQUOTE_B
          return read_string
        elsif b == AT_B
          return read_ivar
        elsif digit?(b)
          return read_number
        elsif ident_start?(b)
          return read_ident_or_keyword
        else
          return read_punct(b)
        end
      end
      Token.new(TokenKind::EOF, 0, "", @line)
    end

    # 文字列リテラル `"..."` を読む。
    # `\n \t \r \\ \" \0` のみ escape 対応。escape 解決後のバイト列を @strlit_pool に
    # 追記し、@strlit_starts/@strlit_lens に新規エントリを追加する。
    # Token の int_value にはそのリテラル idx を入れる。
    # GC-2: literal 領域は @str_pool ではなく @strlit_pool に格納し、heap String の
    # 圧縮 (`gc_compact_pools`) の影響を受けないようにする。
    def read_string
      @lex_pos += 1   # consume opening "
      pool_start = @strlit_pool.length
      while @lex_pos < @bytes.length && @bytes[@lex_pos] != DQUOTE_B
        b = @bytes[@lex_pos]
        if b == BSLASH_B
          if @lex_pos + 1 >= @bytes.length
            raise "Lexer error: line #{@line}: 文字列の終端が見つかりません (escape の後)"
          end
          nb = @bytes[@lex_pos + 1]
          decoded = nb
          if nb == ESC_N_B
            decoded = NL
          elsif nb == ESC_T_B
            decoded = TAB
          elsif nb == ESC_R_B
            decoded = CR_B
          elsif nb == BSLASH_B
            decoded = BSLASH_B
          elsif nb == DQUOTE_B
            decoded = DQUOTE_B
          elsif nb == ESC_ZERO_B
            decoded = NUL_B
          else
            raise "Lexer error: line #{@line}: 未対応の escape (バイト #{nb})"
          end
          @strlit_pool.push(decoded)
          @lex_pos += 2
        else
          # 改行を含むそのままの byte (Ruby と異なり、生改行入り文字列リテラルも許容)。
          if b == NL
            @line += 1
          end
          @strlit_pool.push(b)
          @lex_pos += 1
        end
      end
      if @lex_pos >= @bytes.length
        raise "Lexer error: line #{@line}: 文字列の終端 \" が見つかりません"
      end
      @lex_pos += 1   # consume closing "
      lit_idx = @strlit_starts.length
      @strlit_starts.push(pool_start)
      @strlit_lens.push(@strlit_pool.length - pool_start)
      Token.new(TokenKind::STR, lit_idx, "", @line)
    end

    def digit?(b)
      b >= D0 && b <= D9
    end

    def ident_start?(b)
      (b >= A_LC && b <= Z_LC) || (b >= A_UC && b <= Z_UC) || b == UND
    end

    def ident_cont?(b)
      ident_start?(b) || digit?(b)
    end

    def read_number
      n = 0
      while @lex_pos < @bytes.length && digit?(@bytes[@lex_pos])
        n = n * 10 + (@bytes[@lex_pos] - D0)
        @lex_pos += 1
      end
      Token.new(TokenKind::INT, n, "", @line)
    end

    # `@ident` インスタンス変数を 1 つ読む。`@` の次に通常の識別子が続く必要あり。
    # int_value は packed `(start<<16)|len` で、start は `@` を含む先頭、len は `@` 込みの長さ。
    # 同名のインスタンス変数は同じ packed 値を持つので、ローカル名と同じ流儀で解決できる。
    def read_ivar
      start = @lex_pos
      @lex_pos += 1   # consume `@`
      if @lex_pos >= @bytes.length || !ident_start?(@bytes[@lex_pos])
        raise "Lexer error: line #{@line}: @ の後に識別子が必要です"
      end
      while @lex_pos < @bytes.length && ident_cont?(@bytes[@lex_pos])
        @lex_pos += 1
      end
      len = @lex_pos - start
      packed = (start << 16) | len
      Token.new(TokenKind::IVAR, packed, "", @line)
    end

    def read_ident_or_keyword
      start = @lex_pos
      while @lex_pos < @bytes.length && ident_cont?(@bytes[@lex_pos])
        @lex_pos += 1
      end
      # Stage 3c.3: 識別子末尾の `?` / `!` を 1 byte 取り込む。取り込んだ識別子は常に
      # IDENT (キーワード判定を行わない)。`true?` は KW_TRUE ではなく IDENT として lex。
      if @lex_pos < @bytes.length
        last = @bytes[@lex_pos]
        if last == Q_MARK_B || last == BANG_B
          @lex_pos += 1
          packed = (start << 16) | (@lex_pos - start)
          return Token.new(TokenKind::IDENT, packed, "", @line)
        end
      end
      len = @lex_pos - start
      kw = match_keyword(start, len)
      if kw != :nop
        return Token.new(kw, 0, "", @line)
      end
      # IDENT: 名前は @bytes 上の (start, len) で識別する。
      # 識別子の最大長を 2^16 と仮定し、(start << 16) | len を int_value に格納。
      # Symbol/String を経由せず純粋に整数で扱うことで spinel の型推論を安定させる。
      packed = (start << 16) | len
      Token.new(TokenKind::IDENT, packed, "", @line)
    end

    def match_keyword(start, len)
      result = :nop
      if match_bytes(start, len, KW_PUTS_BYTES)
        result = TokenKind::KW_PUTS
      elsif match_bytes(start, len, KW_TRUE_BYTES)
        result = TokenKind::KW_TRUE
      elsif match_bytes(start, len, KW_FALSE_BYTES)
        result = TokenKind::KW_FALSE
      elsif match_bytes(start, len, KW_NIL_BYTES)
        result = TokenKind::KW_NIL
      elsif match_bytes(start, len, KW_IF_BYTES)
        result = TokenKind::KW_IF
      elsif match_bytes(start, len, KW_ELSIF_BYTES)
        result = TokenKind::KW_ELSIF
      elsif match_bytes(start, len, KW_ELSE_BYTES)
        result = TokenKind::KW_ELSE
      elsif match_bytes(start, len, KW_END_BYTES)
        result = TokenKind::KW_END
      elsif match_bytes(start, len, KW_WHILE_BYTES)
        result = TokenKind::KW_WHILE
      elsif match_bytes(start, len, KW_THEN_BYTES)
        result = TokenKind::KW_THEN
      elsif match_bytes(start, len, KW_DEF_BYTES)
        result = TokenKind::KW_DEF
      elsif match_bytes(start, len, KW_RETURN_BYTES)
        result = TokenKind::KW_RETURN
      elsif match_bytes(start, len, KW_DO_BYTES)
        result = TokenKind::KW_DO
      elsif match_bytes(start, len, KW_YIELD_BYTES)
        result = TokenKind::KW_YIELD
      elsif match_bytes(start, len, KW_CLASS_BYTES)
        result = TokenKind::KW_CLASS
      elsif match_bytes(start, len, KW_SELF_BYTES)
        result = TokenKind::KW_SELF
      elsif match_bytes(start, len, KW_BEGIN_BYTES)
        result = TokenKind::KW_BEGIN
      elsif match_bytes(start, len, KW_RESCUE_BYTES)
        result = TokenKind::KW_RESCUE
      elsif match_bytes(start, len, KW_ENSURE_BYTES)
        result = TokenKind::KW_ENSURE
      elsif match_bytes(start, len, KW_RAISE_BYTES)
        result = TokenKind::KW_RAISE
      elsif match_bytes(start, len, KW_SUPER_BYTES)
        result = TokenKind::KW_SUPER
      elsif match_bytes(start, len, KW_LOOP_BYTES)
        result = TokenKind::KW_LOOP
      elsif match_bytes(start, len, KW_BREAK_BYTES)
        result = TokenKind::KW_BREAK
      elsif match_bytes(start, len, KW_NEXT_BYTES)
        result = TokenKind::KW_NEXT
      end
      result
    end

    def match_bytes(start, len, kw)
      result = false
      if len == kw.length
        ok = true
        i = 0
        while i < len && ok
          if @bytes[start + i] != kw[i]
            ok = false
          end
          i += 1
        end
        result = ok
      end
      result
    end

    def read_punct(b)
      if b == PLUS_BYTE
        @lex_pos += 1
        Token.new(TokenKind::PLUS, 0, "", @line)
      elsif b == MINUS_BYTE
        @lex_pos += 1
        Token.new(TokenKind::MINUS, 0, "", @line)
      elsif b == STAR_BYTE
        @lex_pos += 1
        Token.new(TokenKind::STAR, 0, "", @line)
      elsif b == SLASH_BYTE
        @lex_pos += 1
        Token.new(TokenKind::SLASH, 0, "", @line)
      elsif b == PCT
        @lex_pos += 1
        Token.new(TokenKind::PERCENT, 0, "", @line)
      elsif b == LP
        @lex_pos += 1
        Token.new(TokenKind::LPAREN, 0, "", @line)
      elsif b == RP
        @lex_pos += 1
        Token.new(TokenKind::RPAREN, 0, "", @line)
      elsif b == COMMA_BYTE
        @lex_pos += 1
        Token.new(TokenKind::COMMA, 0, "", @line)
      elsif b == LBRACK_B
        @lex_pos += 1
        Token.new(TokenKind::LBRACK, 0, "", @line)
      elsif b == RBRACK_B
        @lex_pos += 1
        Token.new(TokenKind::RBRACK, 0, "", @line)
      elsif b == LBRACE_B
        @lex_pos += 1
        Token.new(TokenKind::LBRACE, 0, "", @line)
      elsif b == RBRACE_B
        @lex_pos += 1
        Token.new(TokenKind::RBRACE, 0, "", @line)
      elsif b == DOT_BYTE
        @lex_pos += 1
        Token.new(TokenKind::DOT, 0, "", @line)
      elsif b == PIPE_B
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == PIPE_B
          @lex_pos += 2
          Token.new(TokenKind::LOR, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::PIPE, 0, "", @line)
        end
      elsif b == AMP_B
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == AMP_B
          @lex_pos += 2
          Token.new(TokenKind::LAND, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::BAND, 0, "", @line)
        end
      elsif b == CARET_B
        @lex_pos += 1
        Token.new(TokenKind::BXOR, 0, "", @line)
      elsif b == TILDE_B
        @lex_pos += 1
        Token.new(TokenKind::BNOT, 0, "", @line)
      elsif b == BANG_B
        # 識別子末尾の `!` (`destructive!` 等) は read_ident_or_keyword で取り込み済み。
        # ここに来るのは演算子文脈の単独 `!` または `!=`。
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::NEQ, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::NOT, 0, "", @line)
        end
      elsif b == EQ
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::EQ_EQ, 0, "", @line)
        elsif @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == GT_BYTE
          # Stage 3e: `=>` は rescue Class => e の束縛にのみ使う。
          @lex_pos += 2
          Token.new(TokenKind::HASH_ROCKET, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::EQ, 0, "", @line)
        end
      elsif b == LT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::LE, 0, "", @line)
        elsif @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == LT_BYTE
          @lex_pos += 2
          Token.new(TokenKind::LSHIFT, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::LT, 0, "", @line)
        end
      elsif b == GT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::GE, 0, "", @line)
        elsif @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == GT_BYTE
          @lex_pos += 2
          Token.new(TokenKind::SHR, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::GT, 0, "", @line)
        end
      else
        raise "Lexer error: line #{@line}: unexpected byte #{b}"
      end
    end

    # ============================================================
    # Parser (LL(1) pull-style)
    # ============================================================

    def at_end?
      @cur_token.kind == TokenKind::EOF
    end

    def skip_newlines
      while @cur_token.kind == TokenKind::NEWLINE
        @cur_token = next_token
      end
      nil
    end

    def consume_terminator
      k = @cur_token.kind
      if k == TokenKind::NEWLINE || k == TokenKind::EOF
        # OK
      else
        raise "Parse error: line #{@cur_token.line}: 文の終端 (改行 or EOF) が必要です"
      end
      nil
    end

    def expect(kind)
      if @cur_token.kind == kind
        @cur_token = next_token
      else
        raise "Parse error: line #{@cur_token.line}: 期待されたトークンが見つかりません"
      end
      nil
    end

    # statement := 'puts' expression
    #            | 'if' ... 'end'
    #            | 'while' ... 'end'
    #            | 'def' name '(' params ')' body 'end'
    #            | 'return' [expression]
    #            | expression  (代入や var_ref を含む)
    def parse_statement
      k = @cur_token.kind
      if k == TokenKind::KW_PUTS
        @cur_token = next_token
        expr = parse_expression
        return ASTNode.new(:puts_stmt, 0, false, :nop, nil, nil, expr)
      elsif k == TokenKind::KW_IF
        return parse_if
      elsif k == TokenKind::KW_WHILE
        return parse_while
      elsif k == TokenKind::KW_LOOP
        return parse_loop
      elsif k == TokenKind::KW_BREAK
        @cur_token = next_token
        return ASTNode.new(:break_stmt, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_NEXT
        @cur_token = next_token
        return ASTNode.new(:next_stmt, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_DEF
        return parse_def
      elsif k == TokenKind::KW_RETURN
        return parse_return
      elsif k == TokenKind::KW_CLASS
        return parse_class
      else
        return parse_expression
      end
    end

    # `class Name [< Parent] body end` を 1 つ読む。Name は IDENT。
    # 内部は `def` のみ許可。トップレベル定義のみ。
    # Stage 3d.4: 親クラス指定は `< IDENT`。親は事前定義必須 (1-pass コンパイラ制約)。
    # 親情報は :class_parent_ref (node_int_value = parent name packed) として class_def の
    # node_right に attach する。親なしのときは nil。
    def parse_class
      @cur_token = next_token   # consume `class`
      if @cur_token.kind != TokenKind::IDENT
        raise "Parse error: line #{@cur_token.line}: クラス名が必要です"
      end
      name_packed = @cur_token.int_value
      @cur_token = next_token
      parent_node = nil
      if @cur_token.kind == TokenKind::LT
        @cur_token = next_token
        if @cur_token.kind != TokenKind::IDENT
          raise "Parse error: line #{@cur_token.line}: 親クラス名が必要です"
        end
        parent_packed = @cur_token.int_value
        @cur_token = next_token
        parent_node = ASTNode.new(:class_parent_ref, parent_packed, false, :nop, nil, nil, nil)
      end
      skip_newlines
      body = parse_class_body
      expect(TokenKind::KW_END)
      ASTNode.new(:class_def, name_packed, false, :nop, body, parent_node, nil)
    end

    # クラス本体: 0 個以上の `def` を :seq でリンクリスト化。
    # トップレベル parse_block と異なり、終端は KW_END のみ、許可される文も `def` のみ。
    def parse_class_body
      skip_newlines
      if @cur_token.kind == TokenKind::KW_END
        return ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      end
      if @cur_token.kind != TokenKind::KW_DEF
        raise "Parse error: line #{@cur_token.line}: class 内には def のみ書けます (Stage 3d.1)"
      end
      first = parse_def
      skip_newlines
      if @cur_token.kind == TokenKind::KW_END
        return first
      end
      rest = parse_class_body
      ASTNode.new(:seq, 0, false, :nop, first, nil, rest)
    end

    # `yield` / `yield expr` / `yield(expr)` のいずれかを 1 つ読む。多引数は raise。
    # node_left = 引数式 or nil。
    def parse_yield
      @cur_token = next_token   # consume `yield`
      k = @cur_token.kind
      val = nil
      if k == TokenKind::NEWLINE || k == TokenKind::EOF ||
         k == TokenKind::KW_END  || k == TokenKind::KW_ELSE ||
         k == TokenKind::KW_ELSIF
        # 引数なし
      elsif k == TokenKind::LPAREN
        @cur_token = next_token
        if @cur_token.kind != TokenKind::RPAREN
          val = parse_expression
          if @cur_token.kind == TokenKind::COMMA
            raise "Parse error: line #{@cur_token.line}: yield の多引数は Stage 3c.2 スコープ外"
          end
        end
        expect(TokenKind::RPAREN)
      else
        val = parse_expression
        if @cur_token.kind == TokenKind::COMMA
          raise "Parse error: line #{@cur_token.line}: yield の多引数は Stage 3c.2 スコープ外"
        end
      end
      ASTNode.new(:yield_expr, 0, false, :nop, val, nil, nil)
    end

    # 既に primary を 1 つ読み終えた状態から、続く演算子を取り込んで式を完成させる。
    # 最初に postfix (`[i]` / `.name`) を消費してから二項演算チェーンに入る。
    # 高優先度から低優先度へ順に畳み込む (各 `_continue` は左結合で先頭ノードを更新)。
    def parse_expression_from(left, _line)
      left = parse_postfix_from(left)
      left = parse_multiplicative_from(left)
      left = parse_additive_continue(left)
      left = parse_shift_continue(left)
      left = parse_band_continue(left)
      left = parse_bor_continue(left)
      left = parse_rel_continue(left)
      left = parse_eq_continue(left)
      left = parse_and_continue(left)
      left = parse_or_continue(left)
      left
    end

    # `[idx]` (read) / `[idx] = expr` (write) / `.name` / `.name(args)` / `.name do ... end` の
    # postfix チェーン。左結合で繰り返し畳み込む。
    # `[idx] =` の右辺は parse_expression を呼ぶので、`a[i] = b[j] = v` のような
    # 右結合代入も自然に通る。
    def parse_postfix_from(node)
      while @cur_token.kind == TokenKind::LBRACK || @cur_token.kind == TokenKind::DOT
        if @cur_token.kind == TokenKind::LBRACK
          @cur_token = next_token
          idx = parse_expression
          expect(TokenKind::RBRACK)
          if @cur_token.kind == TokenKind::EQ
            @cur_token = next_token
            val = parse_expression
            node = ASTNode.new(:index_set, 0, false, :nop, node, idx, val)
          else
            node = ASTNode.new(:index_get, 0, false, :nop, node, idx, nil)
          end
        else
          @cur_token = next_token   # consume `.`
          if @cur_token.kind != TokenKind::IDENT
            raise "Parse error: line #{@cur_token.line}: . の後にメソッド名が必要です"
          end
          name_packed = @cur_token.int_value
          @cur_token = next_token
          args = nil
          if @cur_token.kind == TokenKind::LPAREN
            @cur_token = next_token
            args = parse_arg_list
            expect(TokenKind::RPAREN)
          end
          # Stage 3c.1/3c.3: 引数並びの直後に `do ... end` または `{ ... }` があればブロックを取り込む。
          # node_right に :block_arg を載せる (compile_method_call_on で each/times/map に展開)。
          block = nil
          if @cur_token.kind == TokenKind::KW_DO || @cur_token.kind == TokenKind::LBRACE
            block = parse_block_arg
          end
          node = ASTNode.new(:method_call_on, name_packed, false, :nop, node, block, args)
        end
      end
      node
    end

    # `do |param| body end` または `{ |param| body }` を 1 つ読む (param なし可)。
    # 多パラメータ `|x, y|` は未対応。
    # node_int_value: param 名 packed (省略時 0)、node_left: ブロック本体
    def parse_block_arg
      brace = @cur_token.kind == TokenKind::LBRACE
      if brace
        expect(TokenKind::LBRACE)
      else
        expect(TokenKind::KW_DO)
      end
      param_packed = 0
      if @cur_token.kind == TokenKind::PIPE
        @cur_token = next_token
        if @cur_token.kind != TokenKind::IDENT
          raise "Parse error: line #{@cur_token.line}: ブロックパラメータ名が必要です"
        end
        param_packed = @cur_token.int_value
        @cur_token = next_token
        if @cur_token.kind == TokenKind::COMMA
          raise "Parse error: line #{@cur_token.line}: 多パラメータブロックはスコープ外"
        end
        expect(TokenKind::PIPE)
      end
      skip_newlines
      if brace
        body = parse_block_seq(BLOCK_SEQ_MODE_BRACE)
        expect(TokenKind::RBRACE)
      else
        body = parse_block_seq(BLOCK_SEQ_MODE_DO_END)
        expect(TokenKind::KW_END)
      end
      ASTNode.new(:block_arg, param_packed, false, :nop, body, nil, nil)
    end

    def parse_multiplicative_from(node)
      loop do
        k = @cur_token.kind
        if k == TokenKind::STAR
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :mul, node, rhs, nil)
        elsif k == TokenKind::SLASH
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :div, node, rhs, nil)
        elsif k == TokenKind::PERCENT
          @cur_token = next_token
          rhs = parse_unary
          node = ASTNode.new(:bin_op, 0, false, :mod, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    def parse_additive_continue(node)
      loop do
        k = @cur_token.kind
        if k == TokenKind::PLUS
          @cur_token = next_token
          rhs = parse_multiplicative
          node = ASTNode.new(:bin_op, 0, false, :add, node, rhs, nil)
        elsif k == TokenKind::MINUS
          @cur_token = next_token
          rhs = parse_multiplicative
          node = ASTNode.new(:bin_op, 0, false, :sub, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    # 整数 AND `&` (左結合)。Ruby precedence: `<< >>` より低く、`| ^` より高い。
    def parse_band_continue(node)
      while @cur_token.kind == TokenKind::BAND
        @cur_token = next_token
        rhs = parse_shift_expr
        node = ASTNode.new(:bin_op, 0, false, :band, node, rhs, nil)
      end
      node
    end

    # 整数 OR `|` / XOR `^` (Ruby と同じく同一レベル、左結合)。
    # ブロックパラメータ `do |x|` の `|` とは文脈が異なる (block_arg は do/{ 直後でしか
    # parse されない) ため衝突しない。
    def parse_bor_continue(node)
      loop do
        k = @cur_token.kind
        if k == TokenKind::PIPE
          @cur_token = next_token
          rhs = parse_band_expr
          node = ASTNode.new(:bin_op, 0, false, :bor, node, rhs, nil)
        elsif k == TokenKind::BXOR
          @cur_token = next_token
          rhs = parse_band_expr
          node = ASTNode.new(:bin_op, 0, false, :bxor, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    # `<<` `>>` は加減と `&` の間。Ruby の優先順位と同じ (左結合)。
    # `a << b << c` → `(a << b) << c`、`a << b + c` → `a << (b + c)`、
    # `1 << 2 | 1` → `(1 << 2) | 1` = 5。
    def parse_shift_continue(node)
      loop do
        k = @cur_token.kind
        if k == TokenKind::LSHIFT
          @cur_token = next_token
          rhs = parse_additive
          node = ASTNode.new(:bin_op, 0, false, :lshift, node, rhs, nil)
        elsif k == TokenKind::SHR
          @cur_token = next_token
          rhs = parse_additive
          node = ASTNode.new(:bin_op, 0, false, :shr, node, rhs, nil)
        else
          break
        end
      end
      node
    end

    # 関係演算 `< > <= >=` (連鎖禁止)。`<<` は parse_shift_continue 側で先に
    # 食われるため、ここに到達する `<` は単独 LT。
    def parse_rel_continue(left)
      tk = @cur_token.kind
      op = :nop
      if tk == TokenKind::LT
        op = :lt
      elsif tk == TokenKind::GT
        op = :gt
      elsif tk == TokenKind::LE
        op = :le
      elsif tk == TokenKind::GE
        op = :ge
      end
      if op != :nop
        @cur_token = next_token
        right = parse_bor_expr
        tk2 = @cur_token.kind
        if tk2 == TokenKind::LT || tk2 == TokenKind::GT ||
           tk2 == TokenKind::LE || tk2 == TokenKind::GE
          raise "Parse error: line #{@cur_token.line}: 比較演算子の連鎖は許可されていません"
        end
        ASTNode.new(:bin_op, 0, false, op, left, right, nil)
      else
        left
      end
    end

    # 等価演算 `== !=` (連鎖禁止、関係演算より低優先度)。
    def parse_eq_continue(left)
      tk = @cur_token.kind
      op = :nop
      if tk == TokenKind::EQ_EQ
        op = :eq
      elsif tk == TokenKind::NEQ
        op = :neq
      end
      if op != :nop
        @cur_token = next_token
        right = parse_rel_expr
        tk2 = @cur_token.kind
        if tk2 == TokenKind::EQ_EQ || tk2 == TokenKind::NEQ
          raise "Parse error: line #{@cur_token.line}: 等価演算子の連鎖は許可されていません"
        end
        ASTNode.new(:bin_op, 0, false, op, left, right, nil)
      else
        left
      end
    end

    # 短絡 AND `&&` (左結合)。bool 中間ローカル変数を作らないため、
    # bytecode は JUMP_IF_FALSE で展開する (compile_expr 側、CLAUDE.md ルール 12)。
    def parse_and_continue(node)
      while @cur_token.kind == TokenKind::LAND
        @cur_token = next_token
        rhs = parse_eq_expr
        node = ASTNode.new(:bin_op, 0, false, :land, node, rhs, nil)
      end
      node
    end

    # 短絡 OR `||` (左結合)。bytecode は JUMP_IF_TRUE で展開する。
    def parse_or_continue(node)
      while @cur_token.kind == TokenKind::LOR
        @cur_token = next_token
        rhs = parse_and_expr
        node = ASTNode.new(:bin_op, 0, false, :lor, node, rhs, nil)
      end
      node
    end

    def parse_if
      # 'if' は既に @cur_token
      @cur_token = next_token
      cond = parse_expression
      skip_then_or_newlines
      then_body = parse_block
      else_body = nil
      k = @cur_token.kind
      if k == TokenKind::KW_ELSIF
        # elsif は新しい if としてネスト
        else_body = parse_if
      elsif k == TokenKind::KW_ELSE
        @cur_token = next_token
        skip_newlines
        else_body = parse_block
        expect(TokenKind::KW_END)
      else
        expect(TokenKind::KW_END)
      end
      ASTNode.new(:if_expr, 0, false, :nop, cond, then_body, else_body)
    end

    def parse_while
      # 'while' は既に @cur_token
      @cur_token = next_token
      cond = parse_expression
      skip_do_or_newlines
      body = parse_block
      expect(TokenKind::KW_END)
      ASTNode.new(:while_stmt, 0, false, :nop, cond, body, nil)
    end

    # `loop do BODY end` を `while true; BODY; end` の構文糖として AST 化する。
    # cond に bool_lit(true) を入れた :while_stmt を返すので compiler 側の特別扱い不要。
    def parse_loop
      @cur_token = next_token   # consume `loop`
      if @cur_token.kind != TokenKind::KW_DO
        raise "Parse error: line #{@cur_token.line}: loop の後に do が必要です"
      end
      @cur_token = next_token   # consume `do`
      skip_newlines
      body = parse_block
      expect(TokenKind::KW_END)
      cond = ASTNode.new(:bool_lit, 0, true, :nop, nil, nil, nil)
      ASTNode.new(:while_stmt, 0, false, :nop, cond, body, nil)
    end

    # def name [( param (, param)* )] body end
    # メソッド定義はトップレベル文。引数 0 個のときは括弧省略可。
    def parse_def
      @cur_token = next_token  # consume `def`
      if @cur_token.kind != TokenKind::IDENT
        raise "Parse error: line #{@cur_token.line}: メソッド名が必要です"
      end
      name_packed = @cur_token.int_value
      @cur_token = next_token

      params = nil
      if @cur_token.kind == TokenKind::LPAREN
        @cur_token = next_token
        params = parse_param_list
        expect(TokenKind::RPAREN)
      end
      skip_newlines
      body = parse_block
      expect(TokenKind::KW_END)
      ASTNode.new(:method_def, name_packed, false, :nop, params, nil, body)
    end

    # 0 個以上のパラメータを :param_cons リンクリストとしてパース。
    # node_int_value: パラメータ名 packed
    # node_operand:   次の :param_cons または nil
    def parse_param_list
      if @cur_token.kind == TokenKind::RPAREN
        return nil
      end
      if @cur_token.kind != TokenKind::IDENT
        raise "Parse error: line #{@cur_token.line}: パラメータ名が必要です"
      end
      pkt = @cur_token.int_value
      @cur_token = next_token
      rest = nil
      if @cur_token.kind == TokenKind::COMMA
        @cur_token = next_token
        rest = parse_param_list
      end
      ASTNode.new(:param_cons, pkt, false, :nop, nil, nil, rest)
    end

    # 0 個以上の引数式を :arg_cons リンクリストとしてパース。
    # node_left:    引数の式 AST
    # node_operand: 次の :arg_cons または nil
    def parse_arg_list
      if @cur_token.kind == TokenKind::RPAREN
        return nil
      end
      arg = parse_expression
      rest = nil
      if @cur_token.kind == TokenKind::COMMA
        @cur_token = next_token
        rest = parse_arg_list
      end
      ASTNode.new(:arg_cons, 0, false, :nop, arg, nil, rest)
    end

    # 配列リテラル `[a, b, c]` の要素リスト。終端は RBRACK。
    # parse_arg_list と同じ :arg_cons チェーン形式 (compile_expr で要素数を数えて
    # ARRAY_NEW operand にする)。
    def parse_array_elements
      if @cur_token.kind == TokenKind::RBRACK
        return nil
      end
      elem = parse_expression
      rest = nil
      if @cur_token.kind == TokenKind::COMMA
        @cur_token = next_token
        rest = parse_array_elements
      end
      ASTNode.new(:arg_cons, 0, false, :nop, elem, nil, rest)
    end

    # return [expression]
    def parse_return
      @cur_token = next_token  # consume `return`
      k = @cur_token.kind
      val = nil
      if k == TokenKind::NEWLINE || k == TokenKind::EOF ||
         k == TokenKind::KW_END  || k == TokenKind::KW_ELSE ||
         k == TokenKind::KW_ELSIF
        val = ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      else
        val = parse_expression
      end
      ASTNode.new(:return_stmt, 0, false, :nop, nil, nil, val)
    end

    def skip_then_or_newlines
      if @cur_token.kind == TokenKind::KW_THEN
        @cur_token = next_token
      end
      skip_newlines
    end

    def skip_do_or_newlines
      # while には Ruby だと do があるが Stage 1 では NEWLINE のみ受ける
      skip_newlines
    end

    # ブロック本体パース mode 定数。
    # do/end は KW_END / KW_ELSE / KW_ELSIF / EOF で終端、中括弧は RBRACE で終端。
    BLOCK_SEQ_MODE_DO_END = 0
    BLOCK_SEQ_MODE_BRACE  = 1

    # 複数文を右結合の :seq チェーンに組み立てる。
    # 文の区切りは NEWLINE または終端キーワードを許す。
    # これにより `if true then 10 else 20 end` のような単一行も書ける。
    def parse_block
      parse_block_seq(BLOCK_SEQ_MODE_DO_END)
    end

    def parse_block_seq(mode)
      skip_newlines
      if at_block_seq_end?(mode)
        return ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      end
      first = parse_statement
      consume_block_seq_terminator(mode)
      skip_newlines
      if at_block_seq_end?(mode)
        return first
      end
      rest = parse_block_seq(mode)
      ASTNode.new(:seq, 0, false, :nop, first, nil, rest)
    end

    def at_block_seq_end?(mode)
      k = @cur_token.kind
      if mode == BLOCK_SEQ_MODE_BRACE
        return k == TokenKind::RBRACE
      end
      # Stage 3e: KW_RESCUE / KW_ENSURE は begin の本体および前の rescue 節を終端させる。
      # begin 以外の context (def 本体や if 本体) で出現した場合は parse_begin_rescue に
      # 戻った時点で「rescue/ensure もない begin」エラーになるか、外側でも未対応として弾かれる。
      k == TokenKind::KW_END || k == TokenKind::KW_ELSE ||
        k == TokenKind::KW_ELSIF || k == TokenKind::EOF ||
        k == TokenKind::KW_RESCUE || k == TokenKind::KW_ENSURE
    end

    def consume_block_seq_terminator(mode)
      k = @cur_token.kind
      if mode == BLOCK_SEQ_MODE_BRACE
        if k == TokenKind::NEWLINE || k == TokenKind::EOF || k == TokenKind::RBRACE
          return nil
        end
        raise "Parse error: line #{@cur_token.line}: 文の終端 (改行/`}`) が必要です"
      end
      if k == TokenKind::NEWLINE || k == TokenKind::EOF ||
         k == TokenKind::KW_END  || k == TokenKind::KW_ELSE ||
         k == TokenKind::KW_ELSIF
        return nil
      end
      raise "Parse error: line #{@cur_token.line}: 文の終端 (改行/end/else/elsif) が必要です"
    end

    # expression := IDENT '=' expression       (代入は右結合)
    #             | IVAR '=' expression        (Stage 3d.1)
    #             | comparison
    # 代入は最も低い優先順位で右結合。`x = y = 1` は `x = (y = 1)` となる。
    def parse_expression
      if @cur_token.kind == TokenKind::IVAR
        # `@var` または `@var = expr`。parse_primary 経路と同じ AST を生成。
        packed = @cur_token.int_value
        line   = @cur_token.line
        @cur_token = next_token
        if @cur_token.kind == TokenKind::EQ
          @cur_token = next_token
          value = parse_expression
          return ASTNode.new(:ivar_assign, packed, false, :nop, value, nil, nil)
        end
        left_node = ASTNode.new(:ivar_ref, packed, false, :nop, nil, nil, nil)
        return parse_expression_from(left_node, line)
      end
      if @cur_token.kind == TokenKind::IDENT
        # IDENT の int_value は (start << 16) | len の packed 値。
        # 名前識別はこの packed 値そのもので比較できる (同じバイト列なら同じ start)。
        # ただし複数回出現する同名識別子は start が違うので、コンパイル時に
        # 「@local_starts/@local_lens に登録されている既存名と byte-equal な範囲かどうか」を
        # 判定して slot を共有する。
        # parser 段階では packed 値をそのまま node_int_value に乗せて compiler に渡す。
        packed = @cur_token.int_value
        line   = @cur_token.line
        @cur_token = next_token
        if @cur_token.kind == TokenKind::EQ
          @cur_token = next_token
          value = parse_expression
          # :assign は名前 packed を node_int_value に格納
          return ASTNode.new(:assign, packed, false, :nop, value, nil, nil)
        elsif @cur_token.kind == TokenKind::LPAREN
          # メソッド呼び出し: ident '(' args ')' [do|{ ... end|}]
          @cur_token = next_token
          args = parse_arg_list
          expect(TokenKind::RPAREN)
          # Stage 3c.2/3c.3: 引数並びの直後に do ... end / { ... } があればブロックを取り込む。
          # method_call の node_right にブロックを attach (method_call_on と同じ規約)。
          block = nil
          if @cur_token.kind == TokenKind::KW_DO || @cur_token.kind == TokenKind::LBRACE
            block = parse_block_arg
          end
          left_node = ASTNode.new(:method_call, packed, false, :nop, args, block, nil)
          return parse_expression_from(left_node, line)
        elsif @cur_token.kind == TokenKind::KW_DO || @cur_token.kind == TokenKind::LBRACE
          # `f do ... end` / `f { ... }` 括弧省略形 → 0-arg method_call + block。
          block = parse_block_arg
          left_node = ASTNode.new(:method_call, packed, false, :nop, nil, block, nil)
          return parse_expression_from(left_node, line)
        else
          left_node = ASTNode.new(:var_ref, packed, false, :nop, nil, nil, nil)
          return parse_expression_from(left_node, line)
        end
      end
      parse_or_expr
    end

    # ---- Stage 4a 演算子優先順位 (低→高) ----
    # Ruby と一致 (`<< >>` は `& | ^` より高優先度)。
    # parse_or_expr (||) → parse_and_expr (&&) → parse_eq_expr (== !=)
    #   → parse_rel_expr (< > <= >=) → parse_bor_expr (| ^) → parse_band_expr (&)
    #   → parse_shift_expr (<< >>) → parse_additive (+ -) → parse_multiplicative (* / %)
    #   → parse_unary (- ~ !)
    # 各 `_continue` は parse_expression_from から再利用する (IDENT/IVAR primary 経由)。
    # `!` は Ruby と同じく単項高優先度 (parse_unary) に置く。
    def parse_or_expr
      parse_or_continue(parse_and_expr)
    end

    def parse_and_expr
      parse_and_continue(parse_eq_expr)
    end

    def parse_eq_expr
      parse_eq_continue(parse_rel_expr)
    end

    def parse_rel_expr
      parse_rel_continue(parse_bor_expr)
    end

    def parse_bor_expr
      parse_bor_continue(parse_band_expr)
    end

    def parse_band_expr
      parse_band_continue(parse_shift_expr)
    end

    def parse_shift_expr
      parse_shift_continue(parse_additive)
    end

    def parse_additive
      node = parse_multiplicative
      parse_additive_continue(node)
    end

    def parse_multiplicative
      node = parse_unary
      parse_multiplicative_from(node)
    end

    def parse_unary
      k = @cur_token.kind
      if k == TokenKind::MINUS
        @cur_token = next_token
        ASTNode.new(:unary_minus, 0, false, :nop, nil, nil, parse_unary)
      elsif k == TokenKind::BNOT
        @cur_token = next_token
        ASTNode.new(:unary_bnot, 0, false, :nop, nil, nil, parse_unary)
      elsif k == TokenKind::NOT
        @cur_token = next_token
        ASTNode.new(:unary_not, 0, false, :nop, nil, nil, parse_unary)
      else
        # 非 IDENT primary (リテラル / 括弧式 / 配列リテラル / method_call) からの postfix
        # を消費する。IDENT 経路は parse_expression が parse_expression_from を経由して
        # 同じ parse_postfix_from を呼ぶため、ここでの呼び出しと二重実行にはならない。
        parse_postfix_from(parse_primary)
      end
    end

    def parse_primary
      k = @cur_token.kind
      if k == TokenKind::INT
        v = @cur_token.int_value
        @cur_token = next_token
        ASTNode.new(:int_lit, v, false, :nop, nil, nil, nil)
      elsif k == TokenKind::STR
        # int_value はリテラル idx (lexer で @strlit_starts/@strlit_lens に登録済み)。
        v = @cur_token.int_value
        @cur_token = next_token
        ASTNode.new(:str_lit, v, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_TRUE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, true, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_FALSE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_NIL
        @cur_token = next_token
        ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_SELF
        @cur_token = next_token
        ASTNode.new(:self_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::IVAR
        # `@var` を読み、続く `=` で代入かどうか判定。
        # 代入は :assign と同じく右結合で parse_expression を呼ぶ。
        packed = @cur_token.int_value
        @cur_token = next_token
        if @cur_token.kind == TokenKind::EQ
          @cur_token = next_token
          value = parse_expression
          return ASTNode.new(:ivar_assign, packed, false, :nop, value, nil, nil)
        end
        ASTNode.new(:ivar_ref, packed, false, :nop, nil, nil, nil)
      elsif k == TokenKind::IDENT
        packed = @cur_token.int_value   # (start << 16) | len の packed 値
        @cur_token = next_token
        if @cur_token.kind == TokenKind::LPAREN
          @cur_token = next_token
          args = parse_arg_list
          expect(TokenKind::RPAREN)
          ASTNode.new(:method_call, packed, false, :nop, args, nil, nil)
        else
          ASTNode.new(:var_ref, packed, false, :nop, nil, nil, nil)
        end
      elsif k == TokenKind::LPAREN
        @cur_token = next_token
        expr = parse_expression
        expect(TokenKind::RPAREN)
        expr
      elsif k == TokenKind::LBRACK
        # 配列リテラル `[a, b, c]`。要素は :arg_cons チェーン (parse_arg_list と同じ形式)。
        @cur_token = next_token
        elems = parse_array_elements
        expect(TokenKind::RBRACK)
        ASTNode.new(:array_lit, 0, false, :nop, elems, nil, nil)
      elsif k == TokenKind::KW_IF
        parse_if
      elsif k == TokenKind::KW_WHILE
        parse_while
      elsif k == TokenKind::KW_LOOP
        parse_loop
      elsif k == TokenKind::KW_YIELD
        parse_yield
      elsif k == TokenKind::KW_BEGIN
        parse_begin_rescue
      elsif k == TokenKind::KW_RAISE
        parse_raise
      elsif k == TokenKind::KW_SUPER
        parse_super
      else
        raise "Parse error: line #{@cur_token.line}: 式が必要です"
      end
    end

    # Stage 3d.5: `super` / `super(args)` / `super()`。
    # AST `:super_call`:
    #   node_left  = :arg_cons チェーン (`super(args)`) または nil (引数省略 = 現メソッドの args をそのまま転送)
    #   node_bool_value = `super()` のように明示的に空 args を書いた場合 true (= 引数なし)、
    #                     bare `super` または `super(args)` の場合は false。
    def parse_super
      @cur_token = next_token   # consume `super`
      explicit_args = false
      args = nil
      if @cur_token.kind == TokenKind::LPAREN
        explicit_args = true
        @cur_token = next_token
        args = parse_arg_list   # 0 個以上 (`super()` も OK)
        expect(TokenKind::RPAREN)
      end
      ASTNode.new(:super_call, 0, explicit_args, :nop, args, nil, nil)
    end

    # Stage 3e: `begin BODY [rescue ...]+ [ensure ...] end`。
    # rescue/ensure のいずれかは必須 (両方欠落はパースエラー)。
    # AST: :begin_rescue (left=body, right=first :rescue_clause チェーン or nil, operand=ensure body or nil)
    def parse_begin_rescue
      @cur_token = next_token   # consume `begin`
      skip_newlines
      body = parse_block_seq(BLOCK_SEQ_MODE_DO_END)
      rescues = parse_rescue_chain
      ensure_body = nil
      if @cur_token.kind == TokenKind::KW_ENSURE
        @cur_token = next_token
        skip_newlines
        ensure_body = parse_block_seq(BLOCK_SEQ_MODE_DO_END)
      end
      if rescues.nil? && ensure_body.nil?
        raise "Parse error: line #{@cur_token.line}: begin には rescue または ensure が必要です"
      end
      expect(TokenKind::KW_END)
      ASTNode.new(:begin_rescue, 0, false, :nop, body, rescues, ensure_body)
    end

    # `rescue [Class] [=> name]` 節の連鎖。最後の節の node_right は nil。
    # AST: :rescue_clause (int_value=class_packed, 0=catch-all,
    #        left=body, right=次の節 or nil, operand=:rescue_bind 子ノード or nil)
    def parse_rescue_chain
      if @cur_token.kind != TokenKind::KW_RESCUE
        return nil
      end
      @cur_token = next_token   # consume `rescue`
      class_packed = 0
      if @cur_token.kind == TokenKind::IDENT
        class_packed = @cur_token.int_value
        @cur_token = next_token
      end
      bind_node = nil
      if @cur_token.kind == TokenKind::HASH_ROCKET
        @cur_token = next_token
        if @cur_token.kind != TokenKind::IDENT
          raise "Parse error: line #{@cur_token.line}: => の後に束縛変数名が必要です"
        end
        bind_packed = @cur_token.int_value
        @cur_token = next_token
        bind_node = ASTNode.new(:rescue_bind, bind_packed, false, :nop, nil, nil, nil)
      end
      skip_newlines
      body = parse_block_seq(BLOCK_SEQ_MODE_DO_END)
      rest = parse_rescue_chain
      ASTNode.new(:rescue_clause, class_packed, false, :nop, body, rest, bind_node)
    end

    # `raise expr` を 1 つ読む。`raise` 単独 (再 raise) は Stage 3e スコープ外。
    def parse_raise
      @cur_token = next_token   # consume `raise`
      arg = parse_expression
      ASTNode.new(:raise, 0, false, :nop, arg, nil, nil)
    end

    # ============================================================
    # Compiler
    # ============================================================

    # compile_stmt は常にスタックに値を 1 つ残す (CRuby YARV の式扱いと同じ)。
    def compile_stmt(node)
      k = node.node_kind
      if k == :puts_stmt
        compile_expr(node.node_operand)
        @bytecode.push(Op::PUTS)   # 値を pop して出力、nil を push (Stage 1 で変更)
      elsif k == :assign
        compile_expr(node.node_left)
        idx = declare_local(node.node_int_value)
        @bytecode.push(Op::STORE_LOCAL)
        encode_signed(idx)
        # STORE_LOCAL は値を残す (代入式の値)
      elsif k == :if_expr
        compile_if(node)
      elsif k == :while_stmt
        compile_while(node)
      elsif k == :seq
        compile_block(node)
      elsif k == :method_def
        compile_method_def(node)
      elsif k == :class_def
        compile_class_def(node)
      elsif k == :return_stmt
        compile_return(node)
      elsif k == :break_stmt
        compile_break
      elsif k == :next_stmt
        compile_next
      else
        compile_expr(node)
      end
      nil
    end

    def compile_block(node)
      if node.node_kind == :seq
        compile_stmt(node.node_left)
        @bytecode.push(Op::POP)
        compile_block(node.node_operand)
      else
        compile_stmt(node)
      end
      nil
    end

    def compile_expr(node)
      k = node.node_kind
      if k == :int_lit
        @bytecode.push(Op::PUSH_INT)
        encode_signed(node.node_int_value)
      elsif k == :str_lit
        # node_int_value = strlit_idx。VM の PUSH_STR が毎回新しいヒープ String を確保する。
        @bytecode.push(Op::PUSH_STR)
        encode_signed(node.node_int_value)
      elsif k == :bool_lit
        if node.node_bool_value
          @bytecode.push(Op::PUSH_TRUE)
        else
          @bytecode.push(Op::PUSH_FALSE)
        end
      elsif k == :nil_lit
        @bytecode.push(Op::PUSH_NIL)
      elsif k == :bin_op
        op = node.node_op
        if op == :land
          compile_short_circuit(node, Op::JUMP_IF_FALSE)
        elsif op == :lor
          compile_short_circuit(node, Op::JUMP_IF_TRUE)
        else
          compile_expr(node.node_left)
          compile_expr(node.node_right)
          opcode = binop_to_opcode(op)
          @bytecode.push(opcode)
          # 新規 Stage 4a opcode は HIR/LIR 未対応のため JIT 不可。
          # 既存 (LSHIFT 等) と区別するため opcode 値で判定する。
          if opcode >= Op::SHL && opcode <= Op::BNOT
            mark_current_method_jit_unsafe
          elsif opcode == Op::NEQ
            mark_current_method_jit_unsafe
          end
        end
      elsif k == :unary_minus
        @bytecode.push(Op::PUSH_INT)
        encode_signed(0)
        compile_expr(node.node_operand)
        @bytecode.push(Op::SUB)
      elsif k == :unary_bnot
        compile_expr(node.node_operand)
        @bytecode.push(Op::BNOT)
        mark_current_method_jit_unsafe
      elsif k == :unary_not
        compile_expr(node.node_operand)
        @bytecode.push(Op::NOT)
        mark_current_method_jit_unsafe
      elsif k == :var_ref
        pkt = node.node_int_value
        idx = find_local(pkt)
        if idx >= 0
          @bytecode.push(Op::LOAD_LOCAL)
          encode_signed(idx)
        elsif method_name_is_block_given?(pkt)
          # Stage 3c.3: block_given? は組み込み 0-arg method として opcode 直接 emit。
          @bytecode.push(Op::BLOCK_GIVEN_P)
        else
          # Ruby と同様、ローカルとして未定義なら 0 引数メソッド呼び出しに解決する。
          m_idx = find_method(pkt)
          if m_idx < 0
            raise "Compile error: line #{@cur_token.line}: undefined local variable or method"
          end
          if @method_arities[m_idx] != 0
            raise "Compile error: line #{@cur_token.line}: 引数の個数が一致しません (期待 #{@method_arities[m_idx]}, 実際 0)"
          end
          @bytecode.push(Op::CALL)
          encode_signed(m_idx)
        end
      elsif k == :assign
        # 式の中の代入 (例: x = (y = 1))
        compile_expr(node.node_left)
        idx = declare_local(node.node_int_value)
        @bytecode.push(Op::STORE_LOCAL)
        encode_signed(idx)
      elsif k == :if_expr
        compile_if(node)
      elsif k == :while_stmt
        compile_while(node)
      elsif k == :seq
        compile_block(node)
      elsif k == :puts_stmt
        # 式の中の puts (puts は nil を push する)
        compile_expr(node.node_operand)
        @bytecode.push(Op::PUTS)
      elsif k == :method_call
        compile_method_call(node)
      elsif k == :array_lit
        compile_array_lit(node)
      elsif k == :index_get
        compile_expr(node.node_left)
        compile_expr(node.node_right)
        @bytecode.push(Op::ARRAY_GET)
      elsif k == :index_set
        compile_expr(node.node_left)
        compile_expr(node.node_right)
        compile_expr(node.node_operand)
        @bytecode.push(Op::ARRAY_SET)
      elsif k == :method_call_on
        compile_method_call_on(node)
      elsif k == :yield_expr
        compile_yield(node)
      elsif k == :self_lit
        @bytecode.push(Op::LOAD_SELF)
      elsif k == :ivar_ref
        compile_ivar_ref(node)
      elsif k == :ivar_assign
        compile_ivar_assign(node)
      elsif k == :begin_rescue
        compile_begin_rescue(node)
      elsif k == :raise
        compile_raise(node)
      elsif k == :super_call
        compile_super(node)
      else
        raise "Compiler bug: unknown expression kind #{k}"
      end
      nil
    end

    # Stage 3d.5: `super` を CALL_SUPER に展開。
    # - bare `super` (node_left == nil, bool_value == false) → 現 method の全パラメータを LOAD_LOCAL で転送。
    # - `super()` (node_left == nil, bool_value == true)     → 0 引数で呼ぶ。
    # - `super(args)` (node_left != nil)                      → args を順に評価して push。
    # - 受信者は @cur_self (CALL_SUPER 内で参照する) なので明示的 LOAD_SELF は不要。
    # - 現在 method の name は @cur_method_name_packed_for_super に compile_method_def が保持。
    # - method 外で super はパースまでは通るが compile 時にエラー。
    def compile_super(node)
      if @cur_method_idx_for_jit < 0
        raise "Compile error: line #{@cur_token.line}: super は method 内でのみ使えます"
      end
      mark_current_method_jit_unsafe   # CALL_SUPER は HIR/LIR 未対応のため
      m_idx = @cur_method_idx_for_jit
      name_packed = (@method_name_starts[m_idx] << 16) | @method_name_lens[m_idx]
      argc = 0
      if node.node_left != nil
        # 明示的 args
        cur = node.node_left
        while cur != nil
          compile_expr(cur.node_left)
          cur = cur.node_operand
        end
        argc = count_arg_chain(node.node_left)
      elsif node.node_bool_value
        # `super()` — 明示的に 0 args
        argc = 0
      else
        # bare `super` — 現 method のパラメータを slot 0..arity-1 から転送。
        argc = @method_arities[m_idx]
        i = 0
        while i < argc
          @bytecode.push(Op::LOAD_LOCAL); encode_signed(i)
          i += 1
        end
      end
      @bytecode.push(Op::CALL_SUPER)
      encode_signed(name_packed)
      encode_signed(argc)
      nil
    end

    # Stage 3e: `raise expr` を bytecode に展開。VM 側 RAISE が値を 1 つ pop し、
    # 文字列なら StandardError でラップ、heap instance ならそのまま例外として伝播する。
    # raise の値は通常は破棄される (rescue されれば rescue body の値、unhandled なら exit) が、
    # 構文上 expression のため compile_stmt の POP 対称性を維持するために PUSH_NIL も emit。
    def compile_raise(node)
      mark_current_method_jit_unsafe
      compile_expr(node.node_left)
      @bytecode.push(Op::RAISE)
      # RAISE は到達した時点で unwind するので RAISE 後の命令は到達しないが、
      # コンパイラ側のスタック整合 (compile_expr は値 1 つを残す契約) を保つため PUSH_NIL を置く。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    # 例外関連 opcode は HIR/LIR でサポートしていないため、現在の method を JIT 対象外にする。
    # method 外 (= top-level / class body 直下) で呼ばれた場合は @cur_method_idx_for_jit が -1
    # なので no-op (top-level は最初から JIT 走査されない)。
    def mark_current_method_jit_unsafe
      if @cur_method_idx_for_jit >= 0
        @jit_call_counts[@cur_method_idx_for_jit] = JIT_HOT_THRESHOLD
      end
      nil
    end

    # Stage 3e: `begin BODY [rescue ...]+ [ensure E] end` を 3 セクションの bytecode に展開。
    # レイアウト:
    #   PUSH_HANDLER catch
    #   <body>; POP                   ; 成功時: body の値を捨てる
    #   POP_HANDLER
    #   JUMP ensure
    #   catch:                          ; rescue 節がなければ catch == ensure に縮退
    #     for each rescue:
    #       CHECK_EXCEPTION_CLASS C   ; -1 = catch-all
    #       JUMP_IF_FALSE next_rescue
    #         [LOAD_EXCEPTION; STORE_LOCAL bind; POP] (bind がある場合のみ)
    #         CLEAR_EXCEPTION
    #         <rescue body>; POP
    #         JUMP ensure
    #       next_rescue:
    #     (どの rescue にもマッチしない: @exception を残したまま fall through)
    #   ensure:
    #     <ensure body>; POP          ; ensure 節がなければスキップ
    #     RERAISE_OR_END               ; @exception 残存なら再 unwind、無ければ次へ
    #   end_label:
    #     PUSH_NIL                     ; begin/rescue 全体の値は nil
    def compile_begin_rescue(node)
      mark_current_method_jit_unsafe
      body        = node.node_left
      rescues     = node.node_right
      ensure_body = node.node_operand

      @bytecode.push(Op::PUSH_HANDLER)
      catch_pos = @bytecode.length
      @bytecode.push(0x80); @bytecode.push(0x80); @bytecode.push(0x00)

      compile_block(body)
      @bytecode.push(Op::POP)
      @bytecode.push(Op::POP_HANDLER)
      jump_to_ensure_success = emit_jump(Op::JUMP)

      # catch_pc target = rescue chain の先頭 (rescue が無ければ ensure 先頭と同じ)。
      patch_jump(catch_pos, @bytecode.length)
      end_jumps = compile_rescue_chain(rescues)

      # ensure_pc target: success path の JUMP と各 rescue マッチ後の JUMP を patch。
      ensure_pc = @bytecode.length
      patch_jump(jump_to_ensure_success, ensure_pc)
      i = 0
      while i < end_jumps.length
        patch_jump(end_jumps[i], ensure_pc)
        i += 1
      end

      if ensure_body != nil
        compile_block(ensure_body)
        @bytecode.push(Op::POP)
      end
      @bytecode.push(Op::RERAISE_OR_END)

      # begin/rescue/ensure 式自体の値は nil (rescue body の値を返す形は Stage 3e スコープ外)。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    # rescue 節のチェーンを順次 emit。各節はマッチ時に ensure へ JUMP する placeholder を
    # IntArray (end_jumps) に貯めて返す。呼び出し側が ensure_pc 確定後に一括 patch する。
    # 引数 cur は ASTNode (:rescue_clause) または nil。spinel 推論を ASTNode にロックさせる
    # ために最初から cur.node_kind を 1 度参照する: assignment 経由のみだと mrb_int に
    # 推論される。
    def compile_rescue_chain(cur)
      end_jumps = []
      while cur != nil
        # ここで cur.node_int_value を読む時点で cur は ASTNode に確定する。
        class_packed = cur.node_int_value
        @bytecode.push(Op::CHECK_EXCEPTION_CLASS)
        if class_packed == 0
          encode_signed(-1)
        else
          cls_idx = find_class_by_packed(class_packed)
          if cls_idx < 0
            raise "Compile error: line #{@cur_token.line}: rescue で参照したクラスが未定義です"
          end
          encode_signed(cls_idx)
        end
        skip_pos = emit_jump(Op::JUMP_IF_FALSE)

        bind_node = cur.node_operand
        if bind_node != nil
          @bytecode.push(Op::LOAD_EXCEPTION)
          slot = declare_local(bind_node.node_int_value)
          @bytecode.push(Op::STORE_LOCAL)
          encode_signed(slot)
          @bytecode.push(Op::POP)
        end
        @bytecode.push(Op::CLEAR_EXCEPTION)

        compile_block(cur.node_left)
        @bytecode.push(Op::POP)
        end_jumps.push(emit_jump(Op::JUMP))

        patch_jump(skip_pos, @bytecode.length)
        cur = cur.node_right
      end
      end_jumps
    end

    # `yield expr` または `yield`。argc は 0 or 1 (Stage 3c.2 制約)。
    # 結果スタックには YIELD opcode が起動した block の return 値が残る。
    def compile_yield(node)
      argc = 0
      if node.node_left != nil
        compile_expr(node.node_left)
        argc = 1
      end
      @bytecode.push(Op::YIELD)
      encode_signed(argc)
      nil
    end

    # `[a, b, c]` を ARRAY_NEW にコンパイル: 各要素を順に push してから ARRAY_NEW size。
    def compile_array_lit(node)
      size = count_arg_chain(node.node_left)
      cur = node.node_left
      while cur != nil
        compile_expr(cur.node_left)
        cur = cur.node_operand
      end
      @bytecode.push(Op::ARRAY_NEW)
      encode_signed(size)
      nil
    end

    # `obj.method(args)` の dispatch。Stage 3b/3c.1 では `length` / `each` / `times` のみ対応。
    # 一般 method dispatch (vtable / hash) は Stage 3d で導入する想定。
    # ASTNode 上の意味割り当て (parse_postfix_from が構築):
    #   node_left    = receiver
    #   node_right   = :block_arg (do |x| body end) or nil
    #   node_operand = :arg_cons チェーン (() の中の引数並び) or nil
    def compile_method_call_on(node)
      name_packed = node.node_int_value
      block       = node.node_right
      argc        = count_arg_chain(node.node_operand)

      # Stage 3d.5: ブロック付き呼び出しは each / times / map も含めてすべて
      # 一般 dispatch (CALL_METHOD_WITH_BLOCK) で扱う。each/map/times は
      # register_builtin_classes_and_methods が Array/Integer の builtin method として
      # 登録する (実装は YIELD opcode を使うループ)。
      if block != nil
        block_pc = compile_inline_block(block)
        block_arity = 0
        if block.node_int_value != 0
          block_arity = 1
        end
        compile_expr(node.node_left)
        cur = node.node_operand
        while cur != nil
          compile_expr(cur.node_left)
          cur = cur.node_operand
        end
        @bytecode.push(Op::CALL_METHOD_WITH_BLOCK)
        encode_signed(name_packed)
        encode_signed(argc)
        encode_signed(block_pc)
        encode_signed(block_arity)
        return nil
      end

      # Stage 3d.1/3d.2: `ClassName.new(args)` はインスタンス確保 + initialize 自動呼び出しに展開。
      # 受信者は :var_ref で、その名前がクラステーブルにあるかで判別する。
      if method_name_is_new?(name_packed) && node.node_left.node_kind == :var_ref
        cls_packed = node.node_left.node_int_value
        cls_idx = find_class_by_packed(cls_packed)
        if cls_idx >= 0
          if block != nil
            raise "Compile error: line #{@cur_token.line}: .new にブロックは渡せません (Stage 3d.2)"
          end
          compile_class_new(cls_idx, node, argc)
          return nil
        end
      end

      # ブロックなしの dispatch (Stage 3b/3d.1)。
      compile_expr(node.node_left)   # receiver
      cur = node.node_operand
      while cur != nil
        compile_expr(cur.node_left)
        cur = cur.node_operand
      end
      # Stage 3d.1/3d.3: 一般 method dispatch。受信者の class を runtime で見て解決。
      # length は Stage 3d.3 で builtin Array class の method として class table に乗ったので
      # ここでの compile-time 特殊形式は不要 (CALL_METHOD で resolve される)。
      @bytecode.push(Op::CALL_METHOD)
      encode_signed(name_packed)
      encode_signed(argc)
      nil
    end

    # ローカル変数表と同様の packed (start<<16)|len 比較で予約 method 名を判定。
    # KW_*_BYTES の定義はクラス先頭の KW_*_BYTES ブロックにある。
    def method_name_is_block_given?(packed)
      method_name_match?(packed, KW_BLOCK_GIVEN_BYTES)
    end

    def method_name_is_new?(packed)
      method_name_match?(packed, KW_NEW_BYTES)
    end

    # Stage 3d.2/3d.4: クラスの initialize method を検索。見つからなければ -1。
    # @bytes 上に "initialize" 文字列が常に含まれる保証はない (ユーザコードに登場しない場合)。
    # よって find_method_in_class (packed name 比較) は使えず、KW_INITIALIZE_BYTES との
    # バイト比較で線形走査する。Stage 3d.4 から parent chain も辿る。
    # find_method_in_chain と同じ while ループ構造で揃えてある (再帰回避)。
    def find_initialize_in_class(class_idx)
      cur = class_idx
      while cur >= -1
        result = find_initialize_in_single_class(cur)
        if result >= 0
          return result
        end
        if cur < 0
          return -1
        end
        cur = @class_parent_idx[cur]
        if cur < 0
          return -1
        end
      end
      -1
    end

    def find_initialize_in_single_class(class_idx)
      i = @method_name_starts.length - 1
      while i >= 0
        if @method_class_idx[i] == class_idx &&
           @method_name_lens[i] == KW_INITIALIZE_BYTES.length &&
           match_bytes(@method_name_starts[i], KW_INITIALIZE_BYTES.length, KW_INITIALIZE_BYTES)
          return i
        end
        i -= 1
      end
      -1
    end

    def method_name_match?(packed, kw_bytes)
      pkg_start = packed >> 16
      pkg_len   = packed & 0xffff
      match_bytes(pkg_start, pkg_len, kw_bytes)
    end

    def compile_if(node)
      # cond
      compile_expr(node.node_left)
      jif_pos = emit_jump(Op::JUMP_IF_FALSE)
      # then 節
      compile_block(node.node_right)
      # then の末尾でジャンプして else を skip
      jend_pos = emit_jump(Op::JUMP)
      # else ラベル
      patch_jump(jif_pos, @bytecode.length)
      if node.node_operand.nil?
        @bytecode.push(Op::PUSH_NIL)
      else
        compile_block(node.node_operand)
      end
      patch_jump(jend_pos, @bytecode.length)
      nil
    end

    def compile_method_def(node)
      if @in_method
        raise "Compile error: メソッド定義はトップレベルでのみ許可されています"
      end

      # トップレベル制御フローからメソッド本体を skip するためのジャンプ。
      skip_jump_pos = emit_jump(Op::JUMP)
      method_pc = @bytecode.length

      name_packed = node.node_int_value
      arity = count_arg_chain(node.node_left)
      m_idx = declare_method(name_packed, method_pc, arity)

      # 新しいスコープに進入。@local_starts/@local_lens は共有のまま、
      # @scope_base 以降を「現在のスコープ」とみなす。
      saved_scope_base = @scope_base
      @scope_base = @local_starts.length
      @in_method = true
      # Stage 3e: raise/begin が出てきたら現在の method を JIT skip にするため、現 m_idx を退避。
      saved_method_idx_for_jit = @cur_method_idx_for_jit
      @cur_method_idx_for_jit = m_idx
      # break/next のスコープを method 境界で切る (外側 loop へ漏らさないため、
      # 現在の loop 深度を barrier として積む。compile_break/next が in_loop_scope? で参照する)。
      push_loop_scope_barrier

      # パラメータを slot 0..argc-1 に登録。declare_local は @scope_base 相対の
      # slot idx (= 0..argc-1) を返す。
      declare_params(node.node_left)

      # body をコンパイル (compile_stmt は常に値を 1 つスタックに残す)。
      compile_stmt(node.node_operand)
      @bytecode.push(Op::RETURN)

      # メソッドのローカル変数総数 (パラメータ + body 内宣言) を確定。
      @method_local_counts[m_idx] = @local_starts.length - @scope_base
      # JIT-2: HIR 構築の範囲を確定 (RETURN push 後の長さ)。
      @method_body_ends[m_idx] = @bytecode.length

      # スコープから抜ける。method 内で使ったローカル名は捨てる。
      while @local_starts.length > @scope_base
        @local_starts.pop
        @local_lens.pop
      end
      @scope_base = saved_scope_base
      @in_method = false
      @cur_method_idx_for_jit = saved_method_idx_for_jit
      pop_loop_scope_barrier

      patch_jump(skip_jump_pos, @bytecode.length)
      # def 文自体の値は nil (compile_stmt の不変条件「1 値残す」を維持)。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    def compile_method_call(node)
      name_packed = node.node_int_value
      block       = node.node_right    # :block_arg or nil (Stage 3c.2)
      argc        = count_arg_chain(node.node_left)
      # Stage 3c.3: block_given? は組み込み 0-arg method (block 不可、引数不可)。
      if method_name_is_block_given?(name_packed)
        if argc != 0 || block != nil
          raise "Compile error: line #{@cur_token.line}: block_given? は引数とブロックを取りません"
        end
        @bytecode.push(Op::BLOCK_GIVEN_P)
        return nil
      end
      m_idx = find_method(name_packed)
      if m_idx < 0
        raise "Compile error: line #{@cur_token.line}: 未定義のメソッド呼び出しです"
      end
      expected = @method_arities[m_idx]
      if expected != argc
        raise "Compile error: line #{@cur_token.line}: 引数の個数が一致しません (期待 #{expected}, 実際 #{argc})"
      end

      block_pc = -1
      block_arity = 0
      if block != nil
        block_pc = compile_inline_block(block)
        if block.node_int_value != 0
          block_arity = 1
        end
      end

      # 引数を左から右の順に評価して push (stack top が最後の引数)。
      cur = node.node_left
      while cur != nil
        compile_expr(cur.node_left)
        cur = cur.node_operand
      end

      if block_pc >= 0
        @bytecode.push(Op::CALL_WITH_BLOCK)
        encode_signed(m_idx)
        encode_signed(block_pc)
        encode_signed(block_arity)
      else
        @bytecode.push(Op::CALL)
        encode_signed(m_idx)
      end
      nil
    end

    # `do |param| body end` ブロックを caller 側の bytecode に inline で配置する
    # (compile_method_def の skip-jump パターンと同形)。戻り値はブロック先頭の PC で
    # CALL_WITH_BLOCK の operand に渡す。
    def compile_inline_block(block_node)
      skip = emit_jump(Op::JUMP)
      block_pc = @bytecode.length
      param_packed = block_node.node_int_value
      if param_packed != 0
        # YIELD は引数 1 個を stack に push してジャンプしてくる。STORE_LOCAL で param へ。
        param_slot = declare_local(param_packed)
        @bytecode.push(Op::STORE_LOCAL)
        encode_signed(param_slot)
        @bytecode.push(Op::POP)
      end
      # ブロック境界で break/next スコープを切る (#40 ではブロックから外側 loop への
      # break/next は対象外)。in_loop_scope? が「barrier より深い loop」のみ可視と判定。
      push_loop_scope_barrier
      # body は最後にスタックへ 1 値を残す不変条件 (compile_block の前提)。
      compile_block(block_node.node_left)
      @bytecode.push(Op::BLOCK_RETURN)
      pop_loop_scope_barrier
      patch_jump(skip, @bytecode.length)
      block_pc
    end

    def compile_return(node)
      if !@in_method
        raise "Compile error: return はメソッド内でのみ使用できます"
      end
      compile_expr(node.node_operand)
      @bytecode.push(Op::RETURN)
      # compile_stmt の「常に 1 値を残す」契約を保つための死コード。
      # 実際の制御フローは到達しない。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    # arg_cons / param_cons リンクリストの長さを数える。
    # spinel が `cur = node` の代入で型推論を壊すため、別ローカル変数を作らず
    # パラメータ自身を再代入してループする。
    def count_arg_chain(node)
      c = 0
      while node != nil
        c += 1
        node = node.node_operand
      end
      c
    end

    def declare_params(node)
      while node != nil
        declare_local(node.node_int_value)
        node = node.node_operand
      end
      nil
    end

    # トップレベル method (class_idx == -1) のみを走査する。同名再定義は最後を採る。
    def find_method(name_packed)
      find_method_in_class(-1, name_packed)
    end

    # Stage 3d.1/3d.4: 指定 class に属する method を後ろから走査。class_idx の class 自身に
    # 見つからなければ Stage 3d.4 で導入された @class_parent_idx を辿って親クラスを検索。
    # class_idx = -1 ならトップレベル method を検索 (parent chain は辿らない)。
    # 末尾再帰は spinel の whole-program 推論で揺れる可能性があるため while ループで実装する
    # (`find_or_declare_ivar_slot` / `total_ivar_count` と同じイテレーションスタイル)。
    def find_method_in_class(class_idx, name_packed)
      pkg_start = name_packed >> 16
      pkg_len   = name_packed & 0xffff
      if pkg_len == 0
        return -1
      end
      find_method_in_chain(class_idx, pkg_start, pkg_len)
    end

    def find_method_in_chain(class_idx, pkg_start, pkg_len)
      cur = class_idx
      while cur >= -1
        result = find_method_in_single_class(cur, pkg_start, pkg_len)
        if result >= 0
          return result
        end
        # cur=-1 (トップレベル) はここで打ち切り (親 chain には進まない)。
        if cur < 0
          return -1
        end
        cur = @class_parent_idx[cur]
        # 親 chain の終端 (= -1) を踏んだらトップレベル method には fall through せず終了。
        if cur < 0
          return -1
        end
      end
      -1
    end

    def find_method_in_single_class(class_idx, pkg_start, pkg_len)
      i = @method_name_starts.length - 1
      while i >= 0
        if @method_class_idx[i] == class_idx &&
           @method_name_lens[i] == pkg_len &&
           bytes_eq(@method_name_starts[i], pkg_start, pkg_len)
          return i
        end
        i -= 1
      end
      -1
    end

    # ============================================================
    # Stage 3d.1: クラス定義 / インスタンス変数 / self
    # ============================================================

    def compile_class_def(node)
      if @in_method
        raise "Compile error: line #{@cur_token.line}: class はトップレベルでのみ定義できます"
      end
      if @cur_class >= 0
        raise "Compile error: line #{@cur_token.line}: ネストしたクラス定義はできません"
      end
      name_packed = node.node_int_value
      # Stage 3d.4: 親クラス参照を解決。:class_parent_ref があれば既存の class table から探す。
      parent_idx = -1
      parent_ref = node.node_right
      if parent_ref != nil
        parent_packed = parent_ref.node_int_value
        parent_idx = find_class_by_packed(parent_packed)
        if parent_idx < 0
          raise "Compile error: line #{@cur_token.line}: 親クラスが未定義です (1-pass コンパイラのため、親は先に定義する必要があります)"
        end
        if parent_idx < BUILTIN_CLASS_COUNT
          raise "Compile error: line #{@cur_token.line}: builtin クラスを親にすることはできません (Stage 3d.4 スコープ外)"
        end
      end
      class_idx = declare_class(name_packed, parent_idx)
      saved_class = @cur_class
      @cur_class = class_idx
      compile_class_body_seq(node.node_left)
      @cur_class = saved_class
      # class def の値は nil (compile_stmt の不変条件「1 値残す」を維持)。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    # クラス本体 (parse_class_body 由来の :seq チェーン or 単一 :method_def or :nil_lit) を
    # コンパイルし、各 method def 後に POP で値を捨てる (compile_class_def 自身が末尾に
    # PUSH_NIL を 1 つ emit する想定)。
    def compile_class_body_seq(node)
      k = node.node_kind
      if k == :nil_lit
        return nil
      end
      if k == :seq
        compile_class_body_member(node.node_left)
        compile_class_body_seq(node.node_operand)
      else
        compile_class_body_member(node)
      end
      nil
    end

    def compile_class_body_member(node)
      if node.node_kind != :method_def
        raise "Compile error: line #{@cur_token.line}: class 内には def のみ"
      end
      compile_method_def(node)        # 末尾に PUSH_NIL を 1 つ残す
      @bytecode.push(Op::POP)         # その PUSH_NIL を消費
      @class_method_counts[@cur_class] = @class_method_counts[@cur_class] + 1
      nil
    end

    # Stage 3d.3: @bytes に builtin method 名のバイト列を prepend し、@lex_pos を user
    # source 開始位置 (= prefix 末尾) に設定する。
    # 現状の prefix レイアウト (将来 builtin を増やしたらここに追加):
    #   - "length"  offset 0, len 6 (KW_LENGTH_BYTES.length)
    # @method_name_starts は prefix 内の offset を指すので、find_method_in_class の
    # bytes_eq が user source 側の同名識別子と正しく match する。
    def init_bytes_with_builtin_prefix(src)
      @bytes = []
      append_bytes(KW_LENGTH_BYTES)
      append_bytes(KW_STDERR_BYTES)
      append_bytes(KW_MESSAGE_BYTES)
      append_bytes(KW_INITIALIZE_BYTES)
      append_bytes(KW_EACH_BYTES)
      append_bytes(KW_MAP_BYTES)
      append_bytes(KW_TIMES_BYTES)
      src_bytes = src.bytes
      i = 0
      while i < src_bytes.length
        @bytes.push(src_bytes[i])
        i += 1
      end
      @lex_pos = PREFIX_TOTAL_LEN
      nil
    end

    def append_bytes(arr)
      i = 0
      while i < arr.length
        @bytes.push(arr[i])
        i += 1
      end
      nil
    end

    # Stage 3d.3: builtin class (Integer/Array/String) を class table 先頭 3 スロットに
    # 匿名で登録 + Array#length を bytecode method として skip-jump パターンで emit する。
    # ユーザコード開始 PC は skip target に揃う (ユーザの method PC 計算は影響を受けない)。
    def register_builtin_classes_and_methods
      i = 0
      while i < BUILTIN_CLASS_COUNT
        # builtin は匿名 (name=(0,0))、親なし。declare_class の重複チェックは
        # find_in_table が pkg_len==0 で即 -1 を返す保護があるため通過する (3 個 pre-register
        # しても問題ない)。これで 7 並列 IntArray の push は declare_class に集約される。
        declare_class(0, -1)
        i += 1
      end

      # Stage 3e: StandardError を名前付きで pre-register。
      # idx は BUILTIN_CLASS_STDERR (= 3) に決まる (BUILTIN_CLASS_COUNT 個 anonymous の後ろ)。
      # ユーザは `raise "msg"` で暗黙にこのクラスのインスタンスを発生させ、
      # `class MyError < StandardError` で継承できる。
      stderr_packed = pack_prefix_name(PREFIX_STDERR_OFFSET, KW_STDERR_BYTES.length)
      stderr_idx    = declare_class(stderr_packed, -1)
      # @message ivar (slot 0) を StandardError 自身に登録。
      @class_ivar_name_starts.push(PREFIX_MESSAGE_OFFSET)
      @class_ivar_name_lens.push(KW_MESSAGE_BYTES.length)
      @class_ivar_counts[stderr_idx] = 1

      # ユーザコード実行は JUMP の patch target から始まるので、その間に builtin の本体を
      # 詰める。method_pc は @bytecode 上の現在位置を記録。
      skip = emit_jump(Op::JUMP)
      saved_class = @cur_class

      # Array#length: arity=0, locals=0, body = LOAD_SELF; ARRAY_LEN; RETURN
      length_packed = pack_prefix_name(PREFIX_LENGTH_OFFSET, KW_LENGTH_BYTES.length)
      register_builtin_method_array_length(length_packed)

      # StandardError#initialize(msg): @message = msg
      init_packed = pack_prefix_name(PREFIX_INIT_OFFSET, KW_INITIALIZE_BYTES.length)
      register_builtin_method_stderr_initialize(stderr_idx, init_packed)

      # StandardError#message: @message を返す
      message_packed = pack_prefix_name(PREFIX_MESSAGE_OFFSET, KW_MESSAGE_BYTES.length)
      register_builtin_method_stderr_message(stderr_idx, message_packed)

      # Stage 3d.5: each / map / times を builtin method として登録。Stage 3c までは
      # コンパイラが call site にループを inline 展開していたが、3d.5 から user-defined
      # method と同じ CALL_METHOD_WITH_BLOCK + YIELD 経路で扱うことで、ASTNode/コンパイラの
      # 特殊化を消す。
      each_packed  = pack_prefix_name(PREFIX_EACH_OFFSET,  KW_EACH_BYTES.length)
      map_packed   = pack_prefix_name(PREFIX_MAP_OFFSET,   KW_MAP_BYTES.length)
      times_packed = pack_prefix_name(PREFIX_TIMES_OFFSET, KW_TIMES_BYTES.length)
      register_builtin_method_array_each(each_packed)
      register_builtin_method_array_map(map_packed)
      register_builtin_method_integer_times(times_packed)

      @cur_class = saved_class
      patch_jump(skip, @bytecode.length)
      nil
    end

    def pack_prefix_name(offset, len)
      (offset << 16) | len
    end

    def register_builtin_method_array_length(name_packed)
      @cur_class = BUILTIN_CLASS_ARRAY
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 0)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::ARRAY_LEN)
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, BUILTIN_CLASS_ARRAY, 0)
      nil
    end

    def register_builtin_method_stderr_initialize(stderr_idx, name_packed)
      @cur_class = stderr_idx
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 1)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)   # msg
      @bytecode.push(Op::STORE_IVAR); encode_signed(0)   # @message slot 0
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, stderr_idx, 1)
      nil
    end

    def register_builtin_method_stderr_message(stderr_idx, name_packed)
      @cur_class = stderr_idx
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 0)
      @bytecode.push(Op::LOAD_IVAR); encode_signed(0)   # @message slot 0
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, stderr_idx, 0)
      nil
    end

    # Array#each: arity=0, block 1引数で各要素を yield。最後に self を返す。
    # block 不在時は最初の YIELD で LocalJumpError (exec_yield 内)。block arity と
    # yield argc がずれても exec_yield (Stage 3d.5 で lenient) が pad/truncate するため
    # `arr.each do; ...; end` (block param 省略) でも動く。
    def register_builtin_method_array_each(name_packed)
      @cur_class = BUILTIN_CLASS_ARRAY
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 0)
      emit_iter_init_counter             # i=0 を slot 0 にセット
      loop_start = @bytecode.length
      emit_iter_loop_guard_array         # i < self.length なら継続
      jexit = emit_jump(Op::JUMP_IF_FALSE)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)
      @bytecode.push(Op::ARRAY_GET)      # self[i]
      @bytecode.push(Op::YIELD); encode_signed(1)
      @bytecode.push(Op::POP)
      emit_iter_increment_counter
      back = emit_jump(Op::JUMP)
      patch_jump(back, loop_start)
      patch_jump(jexit, @bytecode.length)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, BUILTIN_CLASS_ARRAY, 1)
      nil
    end

    # Array#map: arity=0, block の戻り値を新しい配列に集めて返す。
    # locals: slot 0 = i, slot 1 = out (output array)。
    def register_builtin_method_array_map(name_packed)
      @cur_class = BUILTIN_CLASS_ARRAY
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 0)
      emit_iter_init_counter
      @bytecode.push(Op::ARRAY_NEW); encode_signed(0)
      @bytecode.push(Op::STORE_LOCAL); encode_signed(1)
      @bytecode.push(Op::POP)
      loop_start = @bytecode.length
      emit_iter_loop_guard_array
      jexit = emit_jump(Op::JUMP_IF_FALSE)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(1)   # out
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)
      @bytecode.push(Op::ARRAY_GET)
      @bytecode.push(Op::YIELD); encode_signed(1)
      @bytecode.push(Op::LSHIFT)                          # out << yielded
      @bytecode.push(Op::POP)
      emit_iter_increment_counter
      back = emit_jump(Op::JUMP)
      patch_jump(back, loop_start)
      patch_jump(jexit, @bytecode.length)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(1)
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, BUILTIN_CLASS_ARRAY, 2)
      nil
    end

    # Integer#times: arity=0, 0..self-1 まで yield。最後に self を返す。
    def register_builtin_method_integer_times(name_packed)
      @cur_class = BUILTIN_CLASS_INTEGER
      method_pc = @bytecode.length
      m_idx = declare_method(name_packed, method_pc, 0)
      emit_iter_init_counter
      loop_start = @bytecode.length
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::LT)
      jexit = emit_jump(Op::JUMP_IF_FALSE)
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)   # i を yield
      @bytecode.push(Op::YIELD); encode_signed(1)
      @bytecode.push(Op::POP)
      emit_iter_increment_counter
      back = emit_jump(Op::JUMP)
      patch_jump(back, loop_start)
      patch_jump(jexit, @bytecode.length)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::RETURN)
      finalize_builtin_method(m_idx, BUILTIN_CLASS_INTEGER, 1)
      nil
    end

    # Stage 3d.5 builtin iter ヘルパ: slot 0 を 0 で初期化 (i = 0)。
    def emit_iter_init_counter
      @bytecode.push(Op::PUSH_INT); encode_signed(0)
      @bytecode.push(Op::STORE_LOCAL); encode_signed(0)
      @bytecode.push(Op::POP)
      nil
    end

    # i < self.length を bool として stack 上に残す (Array#each / Array#map 用)。
    def emit_iter_loop_guard_array
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)
      @bytecode.push(Op::LOAD_SELF)
      @bytecode.push(Op::ARRAY_LEN)
      @bytecode.push(Op::LT)
      nil
    end

    # i += 1 (slot 0)。
    def emit_iter_increment_counter
      @bytecode.push(Op::LOAD_LOCAL); encode_signed(0)
      @bytecode.push(Op::PUSH_INT); encode_signed(1)
      @bytecode.push(Op::ADD)
      @bytecode.push(Op::STORE_LOCAL); encode_signed(0)
      @bytecode.push(Op::POP)
      nil
    end

    # body emit 後の共通後処理: local count / body_end / class method count / JIT skip。
    def finalize_builtin_method(m_idx, class_idx, local_count)
      @method_local_counts[m_idx] = local_count
      @method_body_ends[m_idx]    = @bytecode.length
      @class_method_counts[class_idx] = @class_method_counts[class_idx] + 1
      # builtin method は JIT hot 検出の対象外 (短くて利得が無い)。
      @jit_call_counts[m_idx] = JIT_HOT_THRESHOLD
      nil
    end

    # 同名クラスの再定義は禁止 (Stage 3d.1 はシンプルに保つ)。
    # Stage 3d.4: parent_idx は親クラス idx (-1 = 親なし)。
    def declare_class(name_packed, parent_idx)
      pkg_start = name_packed >> 16
      pkg_len   = name_packed & 0xffff
      i = find_class_by_packed(name_packed)
      if i >= 0
        raise "Compile error: line #{@cur_token.line}: クラスは既に定義済み (Stage 3d.1)"
      end
      @class_name_starts.push(pkg_start)
      @class_name_lens.push(pkg_len)
      @class_method_starts.push(@method_name_starts.length)
      @class_method_counts.push(0)
      @class_ivar_starts.push(@class_ivar_name_starts.length)
      @class_ivar_counts.push(0)
      @class_parent_idx.push(parent_idx)
      @class_name_starts.length - 1
    end

    def find_class_by_packed(name_packed)
      find_in_table(@class_name_starts, @class_name_lens, 0, name_packed)
    end

    # Stage 3d.2: ClassName.new(args) を compile する。
    # initialize が定義されていれば INSTANCE_NEW + DUP + args + CALL_METHOD initialize + POP
    # の形に展開して new instance をスタックに残す。未定義なら argc==0 を要求し INSTANCE_NEW のみ。
    # method_call_on の node 全体を受け取り、内部で node.node_operand から args chain を辿る。
    # (args chain を別パラメータで受けると spinel の whole-program 推論が混乱する。)
    def compile_class_new(cls_idx, call_node, argc)
      init_idx = find_initialize_in_class(cls_idx)
      if init_idx < 0
        if argc != 0
          raise "Compile error: line #{@cur_token.line}: クラスに initialize が未定義のため引数を渡せません"
        end
        @bytecode.push(Op::INSTANCE_NEW)
        encode_signed(cls_idx)
        return nil
      end
      expected = @method_arities[init_idx]
      if expected != argc
        raise "Compile error: line #{@cur_token.line}: initialize の引数数が一致しません (期待 #{expected}, 実際 #{argc})"
      end
      # INSTANCE_NEW で確保した instance をスタック top と receiver の双方に使うため DUP。
      # CALL_METHOD は受信者の class から find_method_in_class(class_idx, name_packed) で
      # 解決するため、name_packed は @bytes 上の "initialize" バイト列を指していれば良い。
      # find_initialize_in_class が既に該当 entry の m_idx を返しているので、そこから直接
      # packed を組み立てる (別途同じ走査をする synth helper は不要)。
      init_packed = (@method_name_starts[init_idx] << 16) | @method_name_lens[init_idx]
      @bytecode.push(Op::INSTANCE_NEW)
      encode_signed(cls_idx)
      @bytecode.push(Op::DUP)
      cur = call_node.node_operand
      while cur != nil
        compile_expr(cur.node_left)
        cur = cur.node_operand
      end
      @bytecode.push(Op::CALL_METHOD)
      encode_signed(init_packed)
      encode_signed(argc)
      # initialize の戻り値はスタック top に残るが、.new は instance を返すべきなので POP する。
      @bytecode.push(Op::POP)
      nil
    end

    # 現在の class および親 chain の ivar table から name_packed の slot idx を返す。
    # 未登録なら自分の class の末尾に append。Stage 3d.4 で継承対応:
    # - 親で宣言済みの ivar はそのまま親の slot idx を返す (= instance 上の絶対 slot)
    # - 自分で初出現する ivar は ancestor_count + own_count 位置の slot に登録
    # 戻り値は instance ivar pool 上の絶対 slot idx (LOAD_IVAR / STORE_IVAR がそのまま使う)。
    def find_or_declare_ivar_slot(class_idx, name_packed)
      pkg_start = name_packed >> 16
      pkg_len   = name_packed & 0xffff
      # 親 chain を含めて探す
      cur = class_idx
      while cur >= 0
        base = @class_ivar_starts[cur]
        n    = @class_ivar_counts[cur]
        i = 0
        while i < n
          if @class_ivar_name_lens[base + i] == pkg_len &&
             bytes_eq(@class_ivar_name_starts[base + i], pkg_start, pkg_len)
            return ivar_slot_offset_for_class(cur) + i
          end
          i += 1
        end
        cur = @class_parent_idx[cur]
      end
      # どこにもなければ自 class に登録 (絶対 slot は ancestor_count + 既存 own_count)。
      # ivar_slot_offset_for_class(class_idx) は親 chain の合計 (= total_ivar_count(parent)) で
      # 自クラスの count は含まないので、own (= インクリメント前の値) を加算するだけで新 slot の
      # 絶対 idx になる。この「自分の count を含まない offset」という前提が壊れると off-by-own。
      @class_ivar_name_starts.push(pkg_start)
      @class_ivar_name_lens.push(pkg_len)
      own = @class_ivar_counts[class_idx]
      @class_ivar_counts[class_idx] = own + 1
      ivar_slot_offset_for_class(class_idx) + own
    end

    # Stage 3d.4: 当該 class の ivar slot の起点 (= 全祖先の ivar 数の合計、自分は含まない)。
    # parent が -1 のとき total_ivar_count(-1) は while cur >= 0 が即偽になり 0 を返すので両用で安全。
    def ivar_slot_offset_for_class(class_idx)
      total_ivar_count(@class_parent_idx[class_idx])
    end

    # Stage 3d.4: class_idx および全祖先の ivar 数の合計 (= instance の slot 数)。
    def total_ivar_count(class_idx)
      result = 0
      cur = class_idx
      while cur >= 0
        result += @class_ivar_counts[cur]
        cur = @class_parent_idx[cur]
      end
      result
    end

    def compile_ivar_ref(node)
      if @cur_class < 0
        raise "Compile error: line #{@cur_token.line}: @var はクラスメソッド内でのみ使えます"
      end
      slot = find_or_declare_ivar_slot(@cur_class, node.node_int_value)
      @bytecode.push(Op::LOAD_IVAR)
      encode_signed(slot)
      nil
    end

    def compile_ivar_assign(node)
      if @cur_class < 0
        raise "Compile error: line #{@cur_token.line}: @var はクラスメソッド内でのみ使えます"
      end
      compile_expr(node.node_left)
      slot = find_or_declare_ivar_slot(@cur_class, node.node_int_value)
      @bytecode.push(Op::STORE_IVAR)
      encode_signed(slot)
      # STORE_IVAR は値を残す (代入式の値として)
      nil
    end

    # 並列 IntArray (starts, lens) で構成された name table を線形探索する。
    # start_idx 以降だけ走査するので、スコープ相対探索 (find_local) も同じ
    # ヘルパーで賄える。見つかれば絶対 idx を、見つからなければ -1 を返す。
    # pkg_len == 0 は Stage 3c.1 の declare_anonymous_local が使う sentinel と衝突
    # するため必ず -1 を返す (lexer は len>=1 の識別子しか生成しないので packed=0 は
    # 名前検索からは来ないはずだが防御として早期 return)。
    def find_in_table(starts, lens, start_idx, packed)
      pkg_len = packed & 0xffff
      if pkg_len == 0
        return -1
      end
      pkg_start = packed >> 16
      i = start_idx
      result = -1
      while i < starts.length && result < 0
        if lens[i] == pkg_len && bytes_eq(starts[i], pkg_start, pkg_len)
          result = i
        end
        i += 1
      end
      result
    end

    # local_count は body コンパイル後に compile_method_def が確定させる。
    def declare_method(name_packed, method_pc, arity)
      # Stage 3d.1: 常に append し、class_idx も並列に記録する。
      # 同名再定義 (Stage 2 の振る舞い) は find_method 側で「最後に登録された一致」を
      # 返すことで保持。既存テストの top-level method 再定義シナリオはこの仕様で動く。
      @method_name_starts.push(name_packed >> 16)
      @method_name_lens.push(name_packed & 0xffff)
      @method_pcs.push(method_pc)
      @method_arities.push(arity)
      @method_local_counts.push(0)
      @method_body_ends.push(-1)
      @jit_call_counts.push(0)
      @jit_fn_addrs.push(0)
      @jit_fn_sizes.push(0)
      @method_class_idx.push(@cur_class)
      @method_name_starts.length - 1
    end

    def compile_while(node)
      loop_start = @bytecode.length
      # break/next の jump 解決スタックに進入を記録。`next` は loop_start (cond 再評価位置)、
      # `break` は body 末尾以降 (= post-jexit の PUSH_NIL の位置) を target とする。
      @loop_start_pcs.push(loop_start)
      @break_patch_starts.push(@break_patch_pcs.length)

      compile_expr(node.node_left)
      jexit_pos = emit_jump(Op::JUMP_IF_FALSE)
      compile_block(node.node_right)
      @bytecode.push(Op::POP)            # body の値を破棄
      back_jump_pos = emit_jump(Op::JUMP)
      patch_jump(back_jump_pos, loop_start)
      patch_jump(jexit_pos, @bytecode.length)
      # break で飛んでくる目印は jexit と同じ位置。PUSH_NIL の前に patch することで
      # 「break 経由でも while 全体が nil を 1 値残す」不変条件を満たす。
      patch_break_targets(@bytecode.length)
      @bytecode.push(Op::PUSH_NIL)        # while 全体の値は nil
      @loop_start_pcs.pop
      nil
    end

    # @break_patch_pcs の末尾 (現 loop の placeholder 群) を target_abs に patch up し、
    # その分だけ pop する。compile_while 終了時に呼ぶ。
    def patch_break_targets(target_abs)
      start = @break_patch_starts.pop
      while @break_patch_pcs.length > start
        pos = @break_patch_pcs.pop
        patch_jump(pos, target_abs)
      end
      nil
    end

    # method / block 進入時に現在の loop 深度を barrier として積み、退出時に pop する。
    # in_loop_scope? は「barrier より深い loop」のみを可視と判定するため、ブロック / メソッド
    # 境界をまたいで break/next が外側 loop を target にすることを防ぐ。
    def push_loop_scope_barrier
      @loop_scope_barriers.push(@loop_start_pcs.length)
      nil
    end

    def pop_loop_scope_barrier
      @loop_scope_barriers.pop
      nil
    end

    # 現在の compile スコープから見える最内側 loop が存在するか。barrier より深い位置の loop
    # のみを target にできる (= ブロック / メソッド境界をまたぐ break/next は禁止)。
    def in_loop_scope?
      barrier = 0
      if @loop_scope_barriers.length > 0
        barrier = @loop_scope_barriers[@loop_scope_barriers.length - 1]
      end
      @loop_start_pcs.length > barrier
    end

    # `break` / `next` を JUMP に展開する。両者とも JUMP のみで値を push しないが、
    # JUMP 直後のコードは到達不能になるため compile_block の「stmt は 1 値残す」不変条件は
    # 静的には壊れる。HIR builder が踏まないよう mark_current_method_jit_unsafe で除外する。
    def compile_break
      if !in_loop_scope?
        raise "Compile error: line #{@cur_token.line}: break は loop / while の中でのみ使えます"
      end
      pos = emit_jump(Op::JUMP)
      @break_patch_pcs.push(pos)
      mark_current_method_jit_unsafe
      nil
    end

    def compile_next
      if !in_loop_scope?
        raise "Compile error: line #{@cur_token.line}: next は loop / while の中でのみ使えます"
      end
      target = @loop_start_pcs[@loop_start_pcs.length - 1]
      pos = emit_jump(Op::JUMP)
      patch_jump(pos, target)
      mark_current_method_jit_unsafe
      nil
    end

    def binop_to_opcode(op)
      result = 0
      if op == :add
        result = Op::ADD
      elsif op == :sub
        result = Op::SUB
      elsif op == :mul
        result = Op::MUL
      elsif op == :div
        result = Op::DIV
      elsif op == :mod
        result = Op::MOD
      elsif op == :eq
        result = Op::EQ
      elsif op == :lt
        result = Op::LT
      elsif op == :gt
        result = Op::GT
      elsif op == :le
        result = Op::LE
      elsif op == :ge
        result = Op::GE
      elsif op == :lshift
        result = Op::LSHIFT
      # Stage 4a 整数ビット演算 / 不等価。LSHIFT 以外は Fixnum 専用。
      elsif op == :shr
        result = Op::SHR
      elsif op == :band
        result = Op::BAND
      elsif op == :bor
        result = Op::BOR
      elsif op == :bxor
        result = Op::BXOR
      elsif op == :neq
        result = Op::NEQ
      else
        raise "Compiler bug: unknown binop #{op}"
      end
      result
    end

    # `&&` / `||` 共通の短絡展開:
    #   <lhs>
    #   DUP
    #   <jump_op> end        ; && は JUMP_IF_FALSE、|| は JUMP_IF_TRUE
    #   POP
    #   <rhs>
    # end:
    # JUMP_IF_* は cond を pop するため、スキップ時に値を残せるよう DUP+POP で組み立てる。
    # 戻り値は Ruby と同じく短絡時の lhs / 評価時の rhs。
    def compile_short_circuit(node, jump_op)
      compile_expr(node.node_left)
      @bytecode.push(Op::DUP)
      jend = emit_jump(jump_op)
      @bytecode.push(Op::POP)
      compile_expr(node.node_right)
      patch_jump(jend, @bytecode.length)
      mark_current_method_jit_unsafe   # DUP + JUMP_IF_* 経路は HIR 未対応
      nil
    end

    # 可変長 SLEB128 (整数リテラル / STORE_LOCAL/LOAD_LOCAL の slot idx 用)
    def encode_signed(n)
      more = true
      while more
        byte = n & 0x7f
        n = n >> 7
        if (n == 0 && (byte & 0x40) == 0) || (n == -1 && (byte & 0x40) != 0)
          more = false
        else
          byte = byte | 0x80
        end
        @bytecode.push(byte)
      end
      nil
    end

    # ジャンプ用に固定 3バイト SLEB128 を emit する (placeholder)。返り値は patch 用の position。
    # 3 バイトで -1048576..1048575 まで表現可能。
    def emit_jump(opcode)
      @bytecode.push(opcode)
      pos = @bytecode.length
      @bytecode.push(0x80)   # placeholder (continuation)
      @bytecode.push(0x80)   # placeholder (continuation)
      @bytecode.push(0x00)   # placeholder (terminator, will be overwritten)
      pos
    end

    # placeholder 位置を patch する。
    # rel オフセットは「ジャンプオペランド直後 (= pos + 3) から target_abs まで」。
    def patch_jump(placeholder_pos, target_abs)
      rel = target_abs - (placeholder_pos + 3)
      @bytecode[placeholder_pos]     = (rel & 0x7f) | 0x80
      @bytecode[placeholder_pos + 1] = ((rel >> 7) & 0x7f) | 0x80
      @bytecode[placeholder_pos + 2] = (rel >> 14) & 0x7f
      nil
    end

    # ローカル変数表 (packed (start, len) → slot idx)
    # packed は (start_in_bytes << 16) | len の 32bit 値。
    # 同一名 (= byte 等しい) は同じ slot を共有する。
    # @scope_base 以降が現在のスコープ。slot idx はスコープ相対で返す
    # (VM は @locals[@cur_base + idx] で実体にアクセス)。
    def find_local(packed)
      i = find_in_table(@local_starts, @local_lens, @scope_base, packed)
      if i < 0
        i
      else
        i - @scope_base
      end
    end

    def declare_local(packed)
      i = find_local(packed)
      if i < 0
        @local_starts.push(packed >> 16)
        @local_lens.push(packed & 0xffff)
        i = @local_starts.length - 1 - @scope_base
      end
      i
    end

    def lookup_local(packed)
      i = find_local(packed)
      if i < 0
        raise "Compile error: line #{@cur_token.line}: undefined local variable"
      end
      i
    end

    # @bytes 上の 2 範囲 [a..a+len) と [b..b+len) が同一バイト列か?
    def bytes_eq(a, b, len)
      result = true
      j = 0
      while j < len && result
        if @bytes[a + j] != @bytes[b + j]
          result = false
        end
        j += 1
      end
      result
    end

    # ============================================================
    # VM
    # ============================================================

    def run_vm
      @pc = 0
      while true
        op = @bytecode[@pc]
        @pc += 1

        if op == Op::PUSH_INT
          n = decode_signed
          @stack.push(box_int(n))
        elsif op == Op::PUSH_STR
          lit_idx = decode_signed
          @stack.push(heap_str_alloc_from_lit(lit_idx))
        elsif op == Op::PUSH_TRUE
          @stack.push(ObjectVal::TRUE_VAL)
        elsif op == Op::PUSH_FALSE
          @stack.push(ObjectVal::FALSE_VAL)
        elsif op == Op::PUSH_NIL
          @stack.push(ObjectVal::NIL_VAL)
        elsif op == Op::POP
          @stack.pop
        elsif op == Op::STORE_LOCAL
          idx = decode_signed
          @locals[@cur_base + idx] = @stack[@stack.length - 1]   # top を「読む」(pop しない)
        elsif op == Op::LOAD_LOCAL
          idx = decode_signed
          @stack.push(@locals[@cur_base + idx])
        elsif op == Op::JUMP
          rel = decode_signed_3
          @pc = @pc + rel
        elsif op == Op::JUMP_IF_FALSE
          rel = decode_signed_3
          v = @stack.pop
          if !truthy?(v)
            @pc = @pc + rel
          end
        elsif op == Op::JUMP_IF_TRUE
          rel = decode_signed_3
          v = @stack.pop
          if truthy?(v)
            @pc = @pc + rel
          end
        elsif op == Op::ADD
          exec_arith(:add)
        elsif op == Op::SUB
          exec_arith(:sub)
        elsif op == Op::MUL
          exec_arith(:mul)
        elsif op == Op::DIV
          exec_arith(:div)
        elsif op == Op::MOD
          exec_arith(:mod)
        elsif op == Op::EQ
          exec_eq
        elsif op == Op::LT
          exec_compare(:lt)
        elsif op == Op::GT
          exec_compare(:gt)
        elsif op == Op::LE
          exec_compare(:le)
        elsif op == Op::GE
          exec_compare(:ge)
        elsif op == Op::LSHIFT
          exec_lshift
        elsif op == Op::SHR
          exec_int_binop(:shr)
        elsif op == Op::BAND
          exec_int_binop(:band)
        elsif op == Op::BOR
          exec_int_binop(:bor)
        elsif op == Op::BXOR
          exec_int_binop(:bxor)
        elsif op == Op::BNOT
          exec_int_bnot
        elsif op == Op::NEQ
          rhs = @stack.pop
          lhs = @stack.pop
          @stack.push(box_bool(!values_equal?(lhs, rhs)))
        elsif op == Op::NOT
          v = @stack.pop
          @stack.push(box_bool(!truthy?(v)))
        elsif op == Op::ARRAY_NEW
          exec_array_new
        elsif op == Op::ARRAY_GET
          exec_array_get
        elsif op == Op::ARRAY_SET
          exec_array_set
        elsif op == Op::ARRAY_LEN
          exec_array_len
        elsif op == Op::PUTS
          v = @stack.pop
          # Ruby の puts は配列の各要素を別行で出力 (空配列なら何も出力しない)。
          if heap_array?(v)
            puts_array(v)
          else
            puts to_puts_string(v)
          end
          @stack.push(ObjectVal::NIL_VAL)   # Stage 1: puts は nil を返す
        elsif op == Op::CALL
          exec_call
        elsif op == Op::CALL_WITH_BLOCK
          exec_call_with_block
        elsif op == Op::YIELD
          exec_yield
        elsif op == Op::BLOCK_RETURN
          exec_block_return
        elsif op == Op::BLOCK_GIVEN_P
          exec_block_given_p
        elsif op == Op::INSTANCE_NEW
          exec_instance_new
        elsif op == Op::DUP
          exec_dup
        elsif op == Op::CALL_METHOD
          exec_call_method
        elsif op == Op::CALL_METHOD_WITH_BLOCK
          exec_call_method_with_block
        elsif op == Op::LOAD_SELF
          exec_load_self
        elsif op == Op::LOAD_IVAR
          exec_load_ivar
        elsif op == Op::STORE_IVAR
          exec_store_ivar
        elsif op == Op::RETURN
          exec_return
        elsif op == Op::PUSH_HANDLER
          exec_push_handler
        elsif op == Op::POP_HANDLER
          exec_pop_handler
        elsif op == Op::RAISE
          exec_raise
        elsif op == Op::LOAD_EXCEPTION
          @stack.push(@exception)
        elsif op == Op::CLEAR_EXCEPTION
          @exception = ObjectVal::NIL_VAL
        elsif op == Op::CHECK_EXCEPTION_CLASS
          exec_check_exception_class
        elsif op == Op::RERAISE_OR_END
          exec_reraise_or_end
        elsif op == Op::CALL_SUPER
          exec_call_super
        elsif op == Op::HALT
          return nil
        else
          raise "VM error: unknown opcode #{op}"
        end
      end
      nil
    end

    def fixnum?(v)
      (v & 1) == 1
    end

    # Stage 3a/3b: ヒープオブジェクトの判定とタグ付け。下位 3 bit が HEAP_TAG (= 0b110)。
    # Fixnum (LSB=1)、TRUE_VAL=4 (= 0b100)、FALSE_VAL=2 (= 0b010)、NIL_VAL=0 とは
    # 排他的に区別できる。
    # kind 別判定 (heap_str? / heap_array?) は obj_id の tag だけでなく @heap_kind も
    # 確認することで多型ヒープを安全にディスパッチする。
    def heap_obj?(v)
      (v & 7) == HEAP_TAG
    end

    def heap_str?(v)
      heap_obj?(v) && @heap_kind[v >> 3] == HEAP_KIND_STRING
    end

    def heap_array?(v)
      heap_obj?(v) && @heap_kind[v >> 3] == HEAP_KIND_ARRAY
    end

    def box_heap(idx)
      (idx << 3) | HEAP_TAG
    end

    def unbox_heap(v)
      v >> 3
    end

    def truthy?(v)
      v != ObjectVal::NIL_VAL && v != ObjectVal::FALSE_VAL
    end

    def box_int(n)
      (n << 1) | 1
    end

    def unbox_int(v)
      v >> 1
    end

    def box_bool(b)
      if b
        ObjectVal::TRUE_VAL
      else
        ObjectVal::FALSE_VAL
      end
    end

    def to_puts_string(v)
      if fixnum?(v)
        unbox_int(v).to_s
      elsif v == ObjectVal::TRUE_VAL
        "true"
      elsif v == ObjectVal::FALSE_VAL
        "false"
      elsif v == ObjectVal::NIL_VAL
        ""
      elsif heap_str?(v)
        heap_str_to_ruby(v)
      else
        "#<obj>"
      end
    end

    # `puts [1, 2, 3]` → 各要素を別行で出力 (Ruby と同じ)。空配列は何も出力しない。
    # ネスト配列は再帰的に展開。循環参照 (`a << a` 後の `puts a`) で無限再帰しないよう、
    # 深さ上限 (PUTS_ARRAY_MAX_DEPTH) を超えたら明示エラー。Ruby の `[...]` 切替は
    # 循環検出 (visited set) が必要で Stage 3b の SoA IntArray 制約と合わないため、
    # 簡易な深さ制限で代替する。
    PUTS_ARRAY_MAX_DEPTH = 100

    def puts_array(arr_id)
      puts_array_at_depth(arr_id, 0)
      nil
    end

    def puts_array_at_depth(arr_id, depth)
      if depth >= PUTS_ARRAY_MAX_DEPTH
        raise "RuntimeError: puts: 配列がネストしすぎ (循環参照の疑い、深さ #{PUTS_ARRAY_MAX_DEPTH})"
      end
      arr_idx = unbox_heap(arr_id)
      start = @heap_starts[arr_idx]
      len   = @heap_lens[arr_idx]
      i = 0
      while i < len
        e = @heap_arr_pool[start + i]
        if heap_array?(e)
          puts_array_at_depth(e, depth + 1)
        else
          puts to_puts_string(e)
        end
        i += 1
      end
      nil
    end

    # ヒープ String の中身を Ruby String に再構築する (puts 出力経路)。
    # @str_pool[start..start+len-1] のバイトを 1 つずつ chr して連結する。
    # 既存の format_hex32 が `result = result + ...` で文字列連結している前提で
    # spinel が String + String を扱えることに依存している。
    def heap_str_to_ruby(obj_id)
      idx = unbox_heap(obj_id)
      s = @heap_starts[idx]
      l = @heap_lens[idx]
      result = ""
      i = 0
      while i < l
        result = result + @str_pool[s + i].chr
        i += 1
      end
      result
    end

    # @str_pool[src..src+len-1] を末尾に append する追記専用コピー。
    # 自己連結 (lhs == rhs) でも安全: 読み取り元は更新前のまま、書き込みは末尾だけ。
    def str_pool_copy(src, len)
      i = 0
      while i < len
        @str_pool.push(@str_pool[src + i])
        i += 1
      end
      nil
    end

    # GC-2: リテラル領域 (@strlit_pool) から heap String 用の @str_pool 末尾に
    # バイトを append する。@strlit_pool は不変なので read-only コピー。
    def strlit_to_str_pool(src, len)
      i = 0
      while i < len
        @str_pool.push(@strlit_pool[src + i])
        i += 1
      end
      nil
    end

    # リテラル idx から新しいヒープ String を確保する。実行のたびに新スロットを
    # 確保することで、Ruby のリテラル独立性 (`a = "x"; b = "x"; a.equal?(b) == false`) を
    # 自然に得る (== は値比較として別実装)。
    # GC-2: literal バイトは @strlit_pool 上にあるので strlit_to_str_pool 経由で copy する。
    def heap_str_alloc_from_lit(lit_idx)
      # pool 操作の前に GC check。literal バイトはルートに含まれない (@strlit_pool は
      # GC 対象外) ので退避不要。
      gc_check_threshold
      new_start = @str_pool.length
      src_len   = @strlit_lens[lit_idx]
      strlit_to_str_pool(@strlit_starts[lit_idx], src_len)
      alloc_heap_slot(HEAP_KIND_STRING, new_start, src_len, -1)
    end

    # `+`: 新しいヒープ String を確保し、lhs/rhs のバイトを順に append する。
    def heap_str_concat(lhs_id, rhs_id)
      # lhs/rhs は呼び出し側 (exec_arith) で @stack から pop された後の引数。
      # GC 中ルート保護のため一旦 @stack に押し戻して GC を走らせ、その後 pop する。
      # GC 後は @heap_starts[lhs/rhs_idx] が new pool 上の新 offset に更新済み。
      @stack.push(lhs_id)
      @stack.push(rhs_id)
      gc_check_threshold
      @stack.pop
      @stack.pop
      lhs_idx = unbox_heap(lhs_id)
      rhs_idx = unbox_heap(rhs_id)
      ll = @heap_lens[lhs_idx]
      rl = @heap_lens[rhs_idx]
      new_start = @str_pool.length
      str_pool_copy(@heap_starts[lhs_idx], ll)
      str_pool_copy(@heap_starts[rhs_idx], rl)
      alloc_heap_slot(HEAP_KIND_STRING, new_start, ll + rl, -1)
    end

    # ============================================================
    # Garbage Collector (Stage GC-1: STW Mark-Sweep)
    # ============================================================
    # heap slot (@heap_kind / @heap_starts / @heap_lens / @heap_instance_class /
    # @heap_marked の 5 並列) を回収し、freelist に返す。pool 系
    # (@str_pool / @heap_arr_pool / @instance_ivar_pool) は触らない (Stage GC-2 担当)。
    #
    # ルートセット:
    #   - @stack / @locals (VM スタックとローカル変数)
    #   - @cfp_selfs / @cur_self (各フレームの receiver)
    #   - @exception (伝播中の例外オブジェクト)
    #
    # `@strlit_starts` / `@strlit_lens` は @str_pool への直接 offset であり
    # heap slot ではないので GC 対象外。GC-1 では pool を一切触らないため
    # literal バイト領域も影響を受けない。
    #
    # spinel 互換 (CLAUDE.md ルール) のため:
    #   - 再帰なし: explicit stack (@gc_mark_stack) で BFS
    #   - bool ローカル変数を分岐に使わない: 条件式直接判定 / Integer カウンタ
    #   - kind タグは Integer 定数 (HEAP_KIND_*)
    def gc_collect
      # 0. mark stack のリセット。drain ループの自然終端では必ず空になる invariant
      # だが、強制呼び出しなど例外パスで残留する可能性に備えた防御的クリア。
      while @gc_mark_stack.length > 0
        @gc_mark_stack.pop
      end

      # 1. mark phase の準備: @heap_marked を 0 リセット (slot 数分)
      i = 0
      while i < @heap_marked.length
        @heap_marked[i] = 0
        i = i + 1
      end

      # 2. ルート 5 種を mark stack に積む
      gc_push_root(@cur_self)
      gc_push_root(@exception)
      i = 0
      while i < @stack.length
        gc_push_root(@stack[i])
        i = i + 1
      end
      i = 0
      while i < @locals.length
        gc_push_root(@locals[i])
        i = i + 1
      end
      i = 0
      while i < @cfp_selfs.length
        gc_push_root(@cfp_selfs[i])
        i = i + 1
      end

      # 3. mark stack を空になるまで pop して child を辿る
      gc_drain_mark_stack

      # 3.5. (Stage GC-2) live slot の中身を pool に前詰め。
      # mark 済み slot のみ走査するので、sweep より先に行う方が効率的。
      gc_compact_pools

      # 4. sweep phase: 未 mark の live slot を tombstone 化して freelist に返す
      freed = 0
      i = 0
      while i < @heap_kind.length
        if @heap_kind[i] != HEAP_KIND_TOMBSTONE && @heap_marked[i] == 0
          @heap_kind[i] = HEAP_KIND_TOMBSTONE
          @heap_freelist.push(i)
          freed = freed + 1
        end
        i = i + 1
      end

      # 5. 閾値更新 (live * 2、最低 1024 を維持)
      live = @heap_kind.length - @heap_freelist.length
      new_threshold = live * 2
      if new_threshold < 1024
        new_threshold = 1024
      end
      @gc_threshold = new_threshold

      if @dump_gc
        # total = @heap_kind の物理長 (tombstone 含む)、live = GC 後の生存 slot 数、
        # freed = 今回 sweep で新たに tombstone 化した数。
        # str/arr/ivar = 圧縮後の各 pool の長さ (Stage GC-2)。
        STDERR.puts "[gc] total=#{@heap_kind.length} live=#{live} freed=#{freed} " \
                    "str=#{@str_pool.length} arr=#{@heap_arr_pool.length} " \
                    "ivar=#{@instance_ivar_pool.length} threshold=#{@gc_threshold}"
      end
    end

    # ヒープオブジェクト 1 個を mark stack に push する。即値や mark 済みは無視。
    def gc_push_root(v)
      if (v & 7) == HEAP_TAG
        idx = v >> 3
        if @heap_marked[idx] == 0
          @heap_marked[idx] = 1
          @gc_mark_stack.push(idx)
        end
      end
    end

    # mark stack が空になるまで pop して child を mark する。
    # Array は要素 (obj_id) を、Instance は ivar (obj_id) を辿る。String は終端
    # (バイトのみで obj_id を含まない)。tombstone は出現しない (live のみが mark される)。
    def gc_drain_mark_stack
      while @gc_mark_stack.length > 0
        idx = @gc_mark_stack.pop
        k = @heap_kind[idx]
        if k == HEAP_KIND_ARRAY
          s = @heap_starts[idx]
          l = @heap_lens[idx]
          j = 0
          while j < l
            gc_push_root(@heap_arr_pool[s + j])
            j = j + 1
          end
        elsif k == HEAP_KIND_INSTANCE
          s = @heap_starts[idx]
          l = @heap_lens[idx]
          j = 0
          while j < l
            gc_push_root(@instance_ivar_pool[s + j])
            j = j + 1
          end
        end
      end
    end

    # Stage GC-2: live slot の中身を 3 つの flat pool (@str_pool / @heap_arr_pool /
    # @instance_ivar_pool) に前詰めする。relocate-and-grow で積もった abandoned 領域
    # (heap_str_concat / heap_str_append_bang / heap_array_push_bang の旧領域) を回収。
    #
    # 呼び出しタイミングは mark phase 直後・sweep phase 直前。理由:
    #   - mark 済みなら live 確定なので走査対象が絞れる
    #   - sweep 後だと tombstone (kind=0) が残っており分岐が増える
    #
    # slot idx は不変 (slot compaction は GC-3 で対応)。@heap_arr_pool / @instance_ivar_pool
    # 内の obj_id は idx 参照なので「中身を新 pool にコピー」しても書き換え不要。
    # @strlit_pool は GC 対象外 (lex 時に確定する不変領域) なので触らない。
    def gc_compact_pools
      new_str_pool       = []
      new_heap_arr_pool  = []
      new_ivar_pool      = []
      i = 0
      while i < @heap_kind.length
        if @heap_marked[i] == 1
          k         = @heap_kind[i]
          old_start = @heap_starts[i]
          l         = @heap_lens[i]
          if k == HEAP_KIND_STRING
            new_start = new_str_pool.length
            j = 0
            while j < l
              new_str_pool.push(@str_pool[old_start + j])
              j = j + 1
            end
            @heap_starts[i] = new_start
          elsif k == HEAP_KIND_ARRAY
            new_start = new_heap_arr_pool.length
            j = 0
            while j < l
              new_heap_arr_pool.push(@heap_arr_pool[old_start + j])
              j = j + 1
            end
            @heap_starts[i] = new_start
          elsif k == HEAP_KIND_INSTANCE
            new_start = new_ivar_pool.length
            j = 0
            while j < l
              new_ivar_pool.push(@instance_ivar_pool[old_start + j])
              j = j + 1
            end
            @heap_starts[i] = new_start
          end
        end
        i = i + 1
      end
      @str_pool           = new_str_pool
      @heap_arr_pool      = new_heap_arr_pool
      @instance_ivar_pool = new_ivar_pool
      nil
    end

    # Stage 3d.1: ヒープ slot 確保ヘルパ。@heap_kind / @heap_starts / @heap_lens /
    # @heap_instance_class / @heap_marked の 5 並列 IntArray を 1 操作で更新し、
    # 新 obj_id を返す。非インスタンス (string/array) は class_idx = -1 で push する。
    #
    # GC は呼び出し側 (各 alloc ヘルパ) が事前に gc_check_threshold で起動する。
    # ここでは slot 登録のみに専念する。理由: alloc_heap_slot 内で GC を起動すると、
    # 引数 start が呼び出し元で確定済みの「GC 前の pool length」となり、GC-2 の pool
    # 圧縮で pool が縮んだ後に新 slot に書き込まれて範囲外を指すバグになる。
    # spinel rule 6 に従い、戻り値は中間変数 result を経由して返す。
    def alloc_heap_slot(kind, start, len, class_idx)
      result = 0
      if @heap_freelist.length > 0
        idx = @heap_freelist.pop
        @heap_kind[idx]           = kind
        @heap_starts[idx]         = start
        @heap_lens[idx]           = len
        @heap_instance_class[idx] = class_idx
        @heap_marked[idx]         = 0
        result = box_heap(idx)
      else
        @heap_kind.push(kind)
        @heap_starts.push(start)
        @heap_lens.push(len)
        @heap_instance_class.push(class_idx)
        @heap_marked.push(0)
        result = box_heap(@heap_kind.length - 1)
      end
      result
    end

    # alloc サイトから明示的に呼ばれる GC トリガ。pool 操作 (push) を始める **前** に
    # 呼ぶ必要がある。pool 書き込み後に呼ぶと、書き込んだバイトが live slot に紐付く
    # 前に GC が走り、pool 圧縮で書き込みが消える。
    def gc_check_threshold
      live_count = @heap_kind.length - @heap_freelist.length
      if live_count >= @gc_threshold
        gc_collect
      end
    end

    # `<<`: lhs slot の start/len を「新しい末尾位置 + 連結後の長さ」に書き換える
    # (relocate-and-grow)。同じ obj_id を共有する別変数からも更新が見える Ruby 互換の
    # ミューテーション。元の領域は abandon (no-GC)。
    # 自己 append (`s << s`) でも安全: ll/rl とソース start を先に確定してから append し、
    # 最後にスロットを更新するため、読み取り中にソースが書き換わることはない。
    # GC-2 注意: この関数は `alloc_heap_slot` を呼ばないので GC は走らない (pool が
    # 伸びるだけで pool 圧縮の影響は受けない)。よって gc_check_threshold は不要。
    # abandoned 領域は次の alloc で GC が走った時に圧縮される。
    def heap_str_append_bang(lhs_id, rhs_id)
      lhs_idx = unbox_heap(lhs_id)
      rhs_idx = unbox_heap(rhs_id)
      ll = @heap_lens[lhs_idx]
      rl = @heap_lens[rhs_idx]
      new_start = @str_pool.length
      str_pool_copy(@heap_starts[lhs_idx], ll)
      str_pool_copy(@heap_starts[rhs_idx], rl)
      @heap_starts[lhs_idx] = new_start
      @heap_lens[lhs_idx]   = ll + rl
      lhs_id
    end

    # bytes_eq は @bytes 上の比較、こちらは @str_pool 上の比較。同じ Integer 配列上の
    # 範囲比較ロジックなので構造は同型だが、対象配列が違うので別関数に分けてある。
    def pool_bytes_eq(a, b, len)
      mismatch = 0
      i = 0
      while i < len && mismatch == 0
        if @str_pool[a + i] != @str_pool[b + i]
          mismatch = 1
        end
        i += 1
      end
      mismatch == 0
    end

    def heap_str_eq(lhs_id, rhs_id)
      lhs_idx = unbox_heap(lhs_id)
      rhs_idx = unbox_heap(rhs_id)
      ll = @heap_lens[lhs_idx]
      result = false
      if ll == @heap_lens[rhs_idx]
        result = pool_bytes_eq(@heap_starts[lhs_idx], @heap_starts[rhs_idx], ll)
      end
      result
    end

    # ============================================================
    # Stage 3b: 配列ヘルパ
    # ============================================================
    # 配列の要素は @heap_arr_pool に flat に並べる (IntArray of obj_id)。
    # @heap_starts[idx] = pool 開始 element offset、@heap_lens[idx] = 要素数。
    # `<<` は文字列と同じ relocate-and-grow (lhs を pool 末尾に再配置 + 新要素 push)。
    # `[i] = v` はその場で `@heap_arr_pool[start + i] = v`。

    def heap_array_alloc(size)
      # スタックから pop する前に GC check。pop 後の reversed ローカル変数は GC ルートに
      # 含まれないので、pop 後に GC を起動すると要素 (heap obj) が unreachable 扱いになり
      # sweep で消えてしまう。pop 前なら @stack 上の要素はルート保護される。
      gc_check_threshold
      # スタックからの pop はトップから逆順なので、一旦ローカル IntArray に逆順で退避してから
      # @heap_arr_pool に正順で push する。
      reversed = []
      i = 0
      while i < size
        reversed.push(@stack.pop)
        i += 1
      end
      new_start = @heap_arr_pool.length
      i = size - 1
      while i >= 0
        @heap_arr_pool.push(reversed[i])
        i -= 1
      end
      alloc_heap_slot(HEAP_KIND_ARRAY, new_start, size, -1)
    end

    # 配列 obj_id と idx を渡すと、共通の検証 (負 index 拒否) を行ってから
    # heap slot idx を返す。範囲外判定は呼び出し側の責務 (read=nil/write=raise が違うため)。
    def heap_array_resolve(arr_id, idx)
      if idx < 0
        raise "IndexError: 負 index は Stage 3b スコープ外"
      end
      unbox_heap(arr_id)
    end

    # `a[i]` (read)。範囲外 (idx >= len) は Ruby と同じく nil。
    def heap_array_get(arr_id, idx)
      arr_idx = heap_array_resolve(arr_id, idx)
      if idx >= @heap_lens[arr_idx]
        ObjectVal::NIL_VAL
      else
        @heap_arr_pool[@heap_starts[arr_idx] + idx]
      end
    end

    # `a[i] = v` (write)。Ruby は範囲外で nil 埋めで自動拡張するが、Stage 3b では
    # 明示エラーにする (auto-extend は別 PR で扱う余地)。
    def heap_array_set(arr_id, idx, val)
      arr_idx = heap_array_resolve(arr_id, idx)
      len = @heap_lens[arr_idx]
      if idx >= len
        raise "IndexError: 範囲外への代入は Stage 3b スコープ外 (idx=#{idx}, len=#{len})"
      end
      @heap_arr_pool[@heap_starts[arr_idx] + idx] = val
      nil
    end

    # `a << v` (push)。@heap_arr_pool 末尾に「現在の要素 + 新要素」を再配置し、
    # lhs スロットの start/len を更新。共有参照に変更が反映される Ruby 互換セマンティクス。
    # GC-2 注意: heap_str_append_bang と同じく alloc_heap_slot を呼ばないので GC は
    # 走らない。pool が伸びるだけで圧縮の影響は受けず、gc_check_threshold は不要。
    def heap_array_push_bang(arr_id, val)
      arr_idx = unbox_heap(arr_id)
      ll = @heap_lens[arr_idx]
      new_start = @heap_arr_pool.length
      arr_pool_copy(@heap_starts[arr_idx], ll)
      @heap_arr_pool.push(val)
      @heap_starts[arr_idx] = new_start
      @heap_lens[arr_idx]   = ll + 1
      arr_id
    end

    def heap_array_len(arr_id)
      @heap_lens[unbox_heap(arr_id)]
    end

    # @heap_arr_pool[src..src+len-1] を末尾に append する追記専用コピー。
    # str_pool_copy の配列版 (両者とも追記専用 IntArray アリーナ)。
    def arr_pool_copy(src, len)
      i = 0
      while i < len
        @heap_arr_pool.push(@heap_arr_pool[src + i])
        i += 1
      end
      nil
    end

    # 可変長 SLEB128 デコード (bytecode から @pc 起点で)
    def decode_signed
      result = 0
      shift = 0
      done = false
      while !done
        b = @bytecode[@pc]
        @pc += 1
        result = result | ((b & 0x7f) << shift)
        shift += 7
        if (b & 0x80) == 0
          if (b & 0x40) != 0
            result = result | (0 - (1 << shift))
          end
          done = true
        end
      end
      result
    end

    # 固定 3バイト SLEB128 デコード (jump offset 用)
    def decode_signed_3
      b0 = @bytecode[@pc]
      b1 = @bytecode[@pc + 1]
      b2 = @bytecode[@pc + 2]
      @pc += 3
      result = (b0 & 0x7f) | ((b1 & 0x7f) << 7) | ((b2 & 0x7f) << 14)
      if (b2 & 0x40) != 0
        result = result | (0 - (1 << 21))
      end
      result
    end

    def exec_arith(op)
      rhs = @stack.pop
      lhs = @stack.pop
      # Stage 3a: ADD のみ String 連結に多相化。両辺がヒープ String なら新規確保で連結。
      # 片方が String、片方が Fixnum などの混在は TypeError。
      if op == :add && heap_str?(lhs) && heap_str?(rhs)
        @stack.push(heap_str_concat(lhs, rhs))
        return nil
      end
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: arithmetic requires Integer operands"
      end
      # JIT-3c: Fixnum 確定後に観測フラグ (= 「Fixnum で実行された」を意味する)。
      @profile_fixnum_pc[@pc - 1] = 1
      a = unbox_int(lhs)
      b = unbox_int(rhs)
      result = 0
      if op == :add
        result = a + b
      elsif op == :sub
        result = a - b
      elsif op == :mul
        result = a * b
      elsif op == :div
        if b == 0
          raise "ZeroDivisionError: divided by 0"
        end
        result = a / b
      elsif op == :mod
        if b == 0
          raise "ZeroDivisionError: divided by 0"
        end
        result = a % b
      else
        raise "VM bug: unknown arith #{op}"
      end
      @stack.push(box_int(result))
      nil
    end

    def exec_eq
      # JIT-3c: EQ は型違いも許容するが、両辺 Fixnum なら特化対象として観測。
      # Stage 3a: 両辺がヒープ String ならバイト列の値比較。それ以外は obj_id 同値比較
      # (Fixnum/bool/nil のいずれも tagged immediate なので一致が同値と等価)。
      rhs = @stack.pop
      lhs = @stack.pop
      if fixnum?(lhs) && fixnum?(rhs)
        @profile_fixnum_pc[@pc - 1] = 1
        @stack.push(box_bool(lhs == rhs))
      elsif heap_str?(lhs) && heap_str?(rhs)
        @stack.push(box_bool(heap_str_eq(lhs, rhs)))
      else
        @stack.push(box_bool(lhs == rhs))
      end
      nil
    end

    # `<<` は Stage 3a で String × String、Stage 3b で Array × any、Stage 4a で
    # Fixnum × Fixnum (整数左シフト) と多相化されている。
    def exec_lshift
      rhs = @stack.pop
      lhs = @stack.pop
      if heap_str?(lhs) && heap_str?(rhs)
        @stack.push(heap_str_append_bang(lhs, rhs))
      elsif heap_array?(lhs)
        @stack.push(heap_array_push_bang(lhs, rhs))
      elsif fixnum?(lhs) && fixnum?(rhs)
        @stack.push(box_int(unbox_int(lhs) << unbox_int(rhs)))
      else
        raise "TypeError: << は (Integer << Integer) / (String << String) / (Array << any) のみ"
      end
      nil
    end

    # 整数限定の二項ビット演算 (`>> & | ^`)。Fixnum × Fixnum を要求。
    def exec_int_binop(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: bitwise op requires Integer operands"
      end
      a = unbox_int(lhs)
      b = unbox_int(rhs)
      result = 0
      if op == :shr
        result = a >> b
      elsif op == :band
        result = a & b
      elsif op == :bor
        result = a | b
      elsif op == :bxor
        result = a ^ b
      else
        raise "VM bug: unknown int binop #{op}"
      end
      @stack.push(box_int(result))
      nil
    end

    def exec_int_bnot
      v = @stack.pop
      if !fixnum?(v)
        raise "TypeError: ~ requires Integer operand"
      end
      @stack.push(box_int(~unbox_int(v)))
      nil
    end

    # `==` `!=` 共通の値比較。型違いは obj_id 同値、両辺 Fixnum / String なら値比較。
    def values_equal?(lhs, rhs)
      r = false
      if fixnum?(lhs) && fixnum?(rhs)
        r = lhs == rhs
      elsif heap_str?(lhs) && heap_str?(rhs)
        r = heap_str_eq(lhs, rhs)
      else
        r = lhs == rhs
      end
      r
    end

    def exec_array_new
      size = decode_signed
      @stack.push(heap_array_alloc(size))
      nil
    end

    def exec_array_get
      idx_val = @stack.pop
      arr     = @stack.pop
      if !fixnum?(idx_val)
        raise "TypeError: [] の index は Integer 必須"
      end
      if !heap_array?(arr)
        raise "TypeError: [] の receiver は Array 必須 (Stage 3b)"
      end
      @stack.push(heap_array_get(arr, unbox_int(idx_val)))
      nil
    end

    def exec_array_set
      val     = @stack.pop
      idx_val = @stack.pop
      arr     = @stack.pop
      if !fixnum?(idx_val)
        raise "TypeError: []= の index は Integer 必須"
      end
      if !heap_array?(arr)
        raise "TypeError: []= の receiver は Array 必須 (Stage 3b)"
      end
      heap_array_set(arr, unbox_int(idx_val), val)
      @stack.push(val)
      nil
    end

    def exec_array_len
      arr = @stack.pop
      if !heap_array?(arr)
        raise "TypeError: .length の receiver は Array 必須 (Stage 3b)"
      end
      @stack.push(box_int(heap_array_len(arr)))
      nil
    end

    def exec_call
      m_idx = decode_signed
      exec_call_common(m_idx, -1, 0)
      nil
    end

    # Stage 3c.2: ブロック付き呼び出し。block_pc は caller bytecode 上のブロック先頭 PC。
    # block_arity は yield argc とのランタイム不一致を検出するため。
    def exec_call_with_block
      m_idx       = decode_signed
      block_pc    = decode_signed
      block_arity = decode_signed
      exec_call_common(m_idx, block_pc, block_arity)
      nil
    end

    # 共通フレーム push 処理。block_pc=-1 なら通常呼び出し、>=0 ならブロック付き。
    def exec_call_common(m_idx, block_pc, block_arity)
      # JIT-1 プロファイル: 閾値到達後はカウントを止めて以降の配列 write を省く。
      cnt = @jit_call_counts[m_idx]
      if cnt < JIT_HOT_THRESHOLD
        cnt += 1
        @jit_call_counts[m_idx] = cnt
        if cnt == JIT_HOT_THRESHOLD
          STDERR.puts "ZJIT: hot method detected (idx=#{m_idx})"
          # dump 用 / JIT install 用 (いずれも build_and_dump_hir の副作用を必要とする)。
          # AOT 上の build_and_dump_hir には x86_64 ホストで実行すると無限ループ
          # するパスが存在する (= 既存 AOT バグ、現状未調査)。JIT 実機実行が物理的に
          # 不可能な arch では build_and_dump_hir 自体を呼ばないようにしておく。
          if @dump_hir || (@jit_exec_enabled && jit_install_viable?)
            build_and_dump_hir(m_idx)
          end
        end
      end
      argc = @method_arities[m_idx]
      # JIT-4c: install 済みなら直接 callN にディスパッチして bytecode を skip。
      # 失敗マーク (-1) や 0 (未試行) は通常 frame push に流す。
      fn_addr = @jit_fn_addrs[m_idx]
      if fn_addr > 0
        if dispatch_jit_call(m_idx, argc, fn_addr) == 1
          return nil
        end
      end
      local_count = @method_local_counts[m_idx]

      # local_count 個のスロットを NIL_VAL で確保したあと、末尾 argc 個を
      # スタックから逆順 pop で上書きする。3 ループ版より hot path のループ
      # overhead が 1 回分減る。
      new_base = @locals.length
      i = 0
      while i < local_count
        @locals.push(ObjectVal::NIL_VAL)
        i += 1
      end
      i = argc - 1
      while i >= 0
        @locals[new_base + i] = @stack.pop
        i -= 1
      end

      push_call_frame(@pc, @cur_base, m_idx, block_pc, block_arity)
      @cur_base = new_base
      @pc = @method_pcs[m_idx]
      nil
    end

    # コールフレームの並列 IntArray を 1 操作に集約する。フィールド追加時に
    # exec_call_common と exec_return の 2 箇所を同期する手間 (= ドリフト由来のバグ) を防ぐ。
    # Stage 3d.1: @cur_self も同フレームに紐付けて保存する。
    # Stage 3d.5: 「呼び出し元の lexical method」を退避 (yield 時に lexical chain を再現するため)、
    # @yield_target_idx に新フレーム idx を push (このフレームの method 本体実行中の lexical method)。
    # m_idx は super 用 (現フレームの defining class を @method_class_idx から逆引きする)。
    def push_call_frame(pc, base, m_idx, block_pc, block_arity)
      caller_lexical = -1
      if @yield_target_idx.length > 0
        caller_lexical = @yield_target_idx[@yield_target_idx.length - 1]
      end
      @cfp_caller_lexical_method.push(caller_lexical)
      @cfp_pcs.push(pc)
      @cfp_bases.push(base)
      @cfp_block_pcs.push(block_pc)
      @cfp_block_arities.push(block_arity)
      @cfp_selfs.push(@cur_self)
      @cfp_method_idx.push(m_idx)
      @yield_target_idx.push(@cfp_block_pcs.length - 1)
      nil
    end

    # 並列 IntArray を pop し @pc / @cur_base / @cur_self に復元。block 情報は破棄。
    # 複数戻り値で渡すと spinel の poly 推論を誘発しがちなので ivar を直接書き換える。
    def pop_call_frame
      @yield_target_idx.pop
      @cfp_method_idx.pop
      @cfp_block_arities.pop
      @cfp_block_pcs.pop
      @cur_self = @cfp_selfs.pop
      @cur_base = @cfp_bases.pop
      @pc       = @cfp_pcs.pop
      @cfp_caller_lexical_method.pop
      nil
    end

    # Stage 3c.2: yield。現在の lexical method の block_pc に飛び、@cur_base を caller のものに切り替える。
    # @yield_pcs / @yield_bases に method 側の状態を退避し、BLOCK_RETURN で復元する。
    # 引数は YIELD 直前にスタック上に積まれており、ブロックのプロローグが消費する。
    # Stage 3d.5: 「現在の lexical method」は @yield_target_idx.last (cfp.last ではない)。
    # ブロック内 yield (def collect; arr.each do; yield; end; end の collect の yield) が
    # 内側の builtin 呼び出しのフレームを飛び越えて collect のブロックを呼べるようにする。
    def exec_yield
      argc = decode_signed
      target = -1
      if @yield_target_idx.length > 0
        target = @yield_target_idx[@yield_target_idx.length - 1]
      end
      if target < 0 || @cfp_block_pcs[target] < 0
        raise "LocalJumpError: no block given (yield)"
      end
      expected_arity = @cfp_block_arities[target]
      # Ruby 互換: argc と block param 数が違っても error にしない (Stage 3d.5)。
      # argc > expected: 余剰を pop して捨てる。argc < expected: 不足分を nil で埋める。
      # 各 builtin (each/times/map) は arity 1 で yield するが、ユーザの do ... end (arity 0) でも
      # 正常に動作する。
      while argc > expected_arity
        @stack.pop
        argc -= 1
      end
      while argc < expected_arity
        @stack.push(ObjectVal::NIL_VAL)
        argc += 1
      end
      @yield_pcs.push(@pc)
      @yield_bases.push(@cur_base)
      @cur_base = @cfp_bases[target]
      @pc       = @cfp_block_pcs[target]
      # block を実行する間の lexical method は「block 提供元 frame の caller の lexical method」。
      # = @cfp_caller_lexical_method[target]。
      @yield_target_idx.push(@cfp_caller_lexical_method[target])
      nil
    end

    # Stage 3c.2: ブロック本体終端。スタック top はブロックの戻り値 (保持)。
    # Stage 3d.5: yield_target を 1 つ pop して lexical method context を巻き戻す。
    def exec_block_return
      @yield_target_idx.pop
      @pc       = @yield_pcs.pop
      @cur_base = @yield_bases.pop
      nil
    end

    # Stage 3c.3: 現在のフレームが block を受け取って呼ばれていれば true、そうでなければ false。
    # トップレベル (フレームなし) は false を返す (Ruby と同様: トップレベル yield は LocalJumpError)。
    def exec_block_given_p
      # Stage 3d.5: block_given? も yield と同じく lexical method の block を見る。
      target = -1
      if @yield_target_idx.length > 0
        target = @yield_target_idx[@yield_target_idx.length - 1]
      end
      if target < 0 || @cfp_block_pcs[target] < 0
        @stack.push(ObjectVal::FALSE_VAL)
      else
        @stack.push(ObjectVal::TRUE_VAL)
      end
      nil
    end

    # Stage 3d.2: スタック top の値を 1 つ複製。Foo.new(args) の compile-time 展開で使う。
    def exec_dup
      @stack.push(@stack[@stack.length - 1])
      nil
    end

    # Stage 3d.1/3d.4: ClassName.new — class_idx に対応するインスタンスを 1 つ確保する。
    # ivar slot を全 NIL_VAL で初期化し、obj_id を push。Stage 3d.4 から ivar 数は
    # total_ivar_count (= 親祖先 + 自分) を使うことで継承された ivar の slot も確保される。
    def exec_instance_new
      class_idx = decode_signed
      @stack.push(alloc_instance(class_idx))
      nil
    end

    # 指定クラスのインスタンスを 1 つ確保し obj_id を返す (@stack には push しない)。
    # ivar slot は total_ivar_count (親 chain 込み) ぶんを NIL_VAL で初期化する。
    # exec_instance_new と Stage 3e の wrap_str_in_stderr (raise "string" の暗黙ラップ) で共有する。
    def alloc_instance(class_idx)
      # pool 操作 (NIL_VAL push) の前に GC check。NIL_VAL は即値なので GC でも消えない。
      gc_check_threshold
      ivar_count = total_ivar_count(class_idx)
      ivar_start = @instance_ivar_pool.length
      i = 0
      while i < ivar_count
        @instance_ivar_pool.push(ObjectVal::NIL_VAL)
        i += 1
      end
      alloc_heap_slot(HEAP_KIND_INSTANCE, ivar_start, ivar_count, class_idx)
    end

    # Stage 3d.5: super 呼び出し。受信者は @cur_self、検索開始 class は現フレームの method の
    # defining class の親 (= 自分自身は skip)。引数は CALL_SUPER 直前に push 済み。
    def exec_call_super
      name_packed = decode_signed
      argc        = decode_signed
      if @cfp_method_idx.length == 0
        raise "RuntimeError: super はトップレベルでは呼べません"
      end
      cur_m_idx = @cfp_method_idx[@cfp_method_idx.length - 1]
      cur_class = @method_class_idx[cur_m_idx]
      if cur_class < 0
        raise "RuntimeError: super: 現在の method がクラスに属していません"
      end
      parent_class = @class_parent_idx[cur_class]
      if parent_class < 0
        raise "NoMethodError: super: 親クラスがありません"
      end
      m_idx = find_method_in_class(parent_class, name_packed)
      if m_idx < 0
        raise "NoMethodError: super: 親クラス chain に該当 method がありません"
      end
      expected = @method_arities[m_idx]
      if expected != argc
        raise "ArgumentError: super: arity mismatch (expected #{expected}, got #{argc})"
      end
      # 受信者は呼び出し元と同じ self を使い回す (新フレームの @cur_self)。
      receiver = @cur_self
      exec_call_common(m_idx, -1, 0)
      @cur_self = receiver
      nil
    end

    # Stage 3d.1: obj.method(args) の動的ディスパッチ。
    def exec_call_method
      name_packed = decode_signed
      argc        = decode_signed
      exec_dispatch_method(name_packed, argc, -1, 0)
      nil
    end

    # Stage 3d.1: obj.method(args) do |x| ... end の動的ディスパッチ + block 付き。
    def exec_call_method_with_block
      name_packed = decode_signed
      argc        = decode_signed
      block_pc    = decode_signed
      block_arity = decode_signed
      exec_dispatch_method(name_packed, argc, block_pc, block_arity)
      nil
    end

    # CALL_METHOD / CALL_METHOD_WITH_BLOCK の共通ディスパッチ。
    # スタック [..., self, arg1, ..., argN] から self を抜き、args だけ残してから call_common。
    # @cur_self の更新は push_call_frame 完了後に行う (push_call_frame は caller's self を退避する)。
    def exec_dispatch_method(name_packed, argc, block_pc, block_arity)
      self_pos  = @stack.length - argc - 1
      receiver  = @stack[self_pos]
      class_idx = class_of_value(receiver)
      if class_idx < 0
        # nil / true / false 等の class が未対応の値。Stage 3d.3 から Fixnum/Array/String は
        # builtin class を持つので、ここに来るのはそれら以外 (= class_of_value が -1 を返す値)。
        raise "NoMethodError: 受信者の class にこのメソッドはありません (nil/true/false 等は class 未対応)"
      end
      m_idx = find_method_in_class(class_idx, name_packed)
      if m_idx < 0
        raise "NoMethodError: そのクラスに該当 method がありません"
      end
      expected = @method_arities[m_idx]
      if expected != argc
        raise "ArgumentError: arity mismatch (expected #{expected}, got #{argc})"
      end
      # スタック上の self ([-argc-1] 位置) を抜き取って args だけ残す
      # (exec_call_common は最後の argc 個を pop してメソッド locals に書く前提)。
      tmp = []
      i = 0
      while i < argc
        tmp.push(@stack.pop)
        i += 1
      end
      @stack.pop   # discard self (caller's @cur_self は push_call_frame で退避済み)
      i = argc - 1
      while i >= 0
        @stack.push(tmp[i])
        i -= 1
      end
      exec_call_common(m_idx, block_pc, block_arity)
      @cur_self = receiver
      nil
    end

    # 値の class を返す。Stage 3d.3 から builtin (Fixnum/Array/String) も class_idx を返す。
    # ユーザ定義クラスは BUILTIN_CLASS_COUNT 以降の idx に登録される。
    # nil/true/false 等は対応 builtin がまだないため -1 (NoMethodError)。
    def class_of_value(v)
      if (v & 1) == 1
        return BUILTIN_CLASS_INTEGER
      end
      if (v & 7) != HEAP_TAG
        return -1
      end
      idx = v >> 3
      kind = @heap_kind[idx]
      if kind == HEAP_KIND_STRING
        return BUILTIN_CLASS_STRING
      end
      if kind == HEAP_KIND_ARRAY
        return BUILTIN_CLASS_ARRAY
      end
      if kind == HEAP_KIND_INSTANCE
        return @heap_instance_class[idx]
      end
      -1
    end

    def exec_load_self
      @stack.push(@cur_self)
      nil
    end

    def exec_load_ivar
      slot = decode_signed
      if (@cur_self & 7) != HEAP_TAG || @heap_kind[@cur_self >> 3] != HEAP_KIND_INSTANCE
        raise "RuntimeError: @var の self がインスタンスではありません"
      end
      idx = @cur_self >> 3
      @stack.push(@instance_ivar_pool[@heap_starts[idx] + slot])
      nil
    end

    def exec_store_ivar
      slot = decode_signed
      if (@cur_self & 7) != HEAP_TAG || @heap_kind[@cur_self >> 3] != HEAP_KIND_INSTANCE
        raise "RuntimeError: @var の self がインスタンスではありません"
      end
      idx = @cur_self >> 3
      v = @stack[@stack.length - 1]   # peek (代入は値を残す)
      @instance_ivar_pool[@heap_starts[idx] + slot] = v
      nil
    end

    # Stage 3e: PUSH_HANDLER は begin の入口で例外ハンドラを 1 つ登録する。
    # operand は catch_pc の 3-byte SLEB 相対 offset。decode_signed_3 後の @pc を base に
    # 絶対 PC を計算するので、`@pc + rel == target_abs` が成立する
    # (patch_jump がそのように rel を計算しているため)。
    def exec_push_handler
      catch_rel = decode_signed_3
      catch_abs = @pc + catch_rel
      @handler_catch_pcs.push(catch_abs)
      @handler_stack_depths.push(@stack.length)
      @handler_cfp_depths.push(@cfp_pcs.length)
      @handler_yield_depths.push(@yield_pcs.length)
      nil
    end

    def exec_pop_handler
      @handler_yield_depths.pop
      @handler_cfp_depths.pop
      @handler_stack_depths.pop
      @handler_catch_pcs.pop
      nil
    end

    # Stage 3e: RAISE は stack top を例外として取り、必要なら StandardError でラップ、
    # ハンドラスタックの top に向けて unwind する (cfp / yield / stack 全てを当時の深さに戻す)。
    # ハンドラが無ければ Ruby レベルの raise で plain な abort に到達する (CRuby/spinel 共通)。
    def exec_raise
      v = @stack.pop
      @exception = wrap_as_exception(v)
      unwind_to_handler
      nil
    end

    # heap String → StandardError ラップ。heap Instance はそのまま。それ以外は型エラー。
    def wrap_as_exception(v)
      if heap_str?(v)
        wrap_str_in_stderr(v)
      elsif heap_obj?(v) && @heap_kind[v >> 3] == HEAP_KIND_INSTANCE
        v
      else
        raise "TypeError: raise の引数は String または Exception instance のみ可能です"
      end
    end

    # 文字列を @message として持つ StandardError instance を直接構築する。
    # initialize 呼び出しを経由せず alloc_instance で確保したあと slot 0 に直接書く
    # (StandardError#initialize と等価だが VM-internal の最短パス)。
    def wrap_str_in_stderr(str_id)
      obj_id = alloc_instance(BUILTIN_CLASS_STDERR)
      @instance_ivar_pool[@heap_starts[obj_id >> 3]] = str_id   # @message slot 0
      obj_id
    end

    def unwind_to_handler
      if @handler_catch_pcs.length == 0
        unhandled_exception_abort
      end
      stack_depth = @handler_stack_depths.pop
      cfp_depth   = @handler_cfp_depths.pop
      yield_depth = @handler_yield_depths.pop
      catch_abs   = @handler_catch_pcs.pop
      while @cfp_pcs.length > cfp_depth
        # @locals も対応スコープ分破棄。pop_call_frame は @cur_base を caller のものに戻すので、
        # その前に「現フレームのローカル領域」を捨てる必要がある。
        while @locals.length > @cur_base
          @locals.pop
        end
        pop_call_frame
      end
      while @yield_pcs.length > yield_depth
        @yield_bases.pop
        @yield_pcs.pop
        # Stage 3d.5: 各 YIELD は @yield_target_idx を 1 push しているので、巻き戻しも同期。
        @yield_target_idx.pop
      end
      while @stack.length > stack_depth
        @stack.pop
      end
      @pc = catch_abs
      nil
    end

    # ハンドラが無い状態で raise が起きたらプロセスを abort させる (Ruby レベル raise で stderr へ流す)。
    def unhandled_exception_abort
      cls_idx = class_of_value(@exception)
      cls_name = bytes_to_ruby(@class_name_starts[cls_idx], @class_name_lens[cls_idx])
      msg_val = ObjectVal::NIL_VAL
      # @message は StandardError 由来なら slot 0 にある。継承先 (own ivars 0) でも instance の
      # @heap_lens が total_ivar_count を反映しているのでそれで存在を判定する。
      idx = @exception >> 3
      if @heap_lens[idx] > 0
        msg_val = @instance_ivar_pool[@heap_starts[idx]]
      end
      msg_str = ""
      if heap_str?(msg_val)
        msg_str = heap_str_to_ruby(msg_val)
      end
      raise "#{cls_name}: #{msg_str}"
    end

    # @bytes 上の (start, len) を Ruby String 化。class 名/ivar 名の表示用。
    def bytes_to_ruby(start, len)
      result = ""
      i = 0
      while i < len
        result = result + @bytes[start + i].chr
        i += 1
      end
      result
    end

    # CHECK_EXCEPTION_CLASS class_idx — operand が -1 のときは catch-all (常に true)。
    # それ以外のときは @exception の class が class_idx もしくはその先祖クラスかどうかを判定する
    # (Ruby の rescue 節と同じ is_a? semantics、Stage 3d.4 で導入した親 chain を walk)。
    def exec_check_exception_class
      target_idx = decode_signed
      matched = target_idx < 0 || is_subclass?(class_of_value(@exception), target_idx)
      if matched
        @stack.push(ObjectVal::TRUE_VAL)
      else
        @stack.push(ObjectVal::FALSE_VAL)
      end
      nil
    end

    # child_idx が ancestor_idx と等しいか、その先祖チェーンに含まれるかを判定する。
    # @class_parent_idx を walk するだけのシンプルなヘルパで、ancestor_idx == child_idx も
    # true を返す (=== Class semantics と同じ)。
    def is_subclass?(child_idx, ancestor_idx)
      cur = child_idx
      while cur >= 0
        if cur == ancestor_idx
          return true
        end
        cur = @class_parent_idx[cur]
      end
      false
    end

    # ensure 末尾。@exception が残っていれば再度 unwind (上位ハンドラへ伝播)、
    # 残っていなければそのまま次の命令 (PUSH_NIL → end_label) へ進む。
    def exec_reraise_or_end
      if @exception != ObjectVal::NIL_VAL
        unwind_to_handler
      end
      nil
    end

    def exec_return
      v = @stack.pop
      # 自スコープのローカル領域を破棄 (caller の base に戻す)。
      while @locals.length > @cur_base
        @locals.pop
      end
      pop_call_frame   # Stage 3d.1: pop_call_frame 内で @cur_self も復元
      @stack.push(v)
      nil
    end

    def exec_compare(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: comparison requires Integer operands"
      end
      # JIT-3c: Fixnum 確定後に観測フラグ (exec_arith / exec_eq と同じ規約)。
      @profile_fixnum_pc[@pc - 1] = 1
      a = unbox_int(lhs)
      b = unbox_int(rhs)
      r = false
      if op == :lt
        r = a < b
      elsif op == :gt
        r = a > b
      elsif op == :le
        r = a <= b
      elsif op == :ge
        r = a >= b
      else
        raise "VM bug: unknown compare #{op}"
      end
      @stack.push(box_bool(r))
      nil
    end

    # ============================================================
    # JIT-2: HIR 構築 + ダンプ
    # ============================================================

    # ホット検出時にメソッド本体の bytecode を lite SSA HIR に変換し、
    # SETSUNARUBY_DUMP_HIR=1 のとき STDERR に表示する。
    # phi は挿入せず、合流点は STORE_LOCAL/LOAD_LOCAL で表現する半 SSA。
    # `@pc` を一時的に decode_signed のために借用する (VM 実行中の値は
    # `saved_pc` に退避)。
    def build_and_dump_hir(m_idx)
      @hir_kind = []
      @hir_op0  = []
      @hir_op1  = []
      @hir_op2  = []
      @hir_call_args = []
      @hir_deleted   = []
      @hir_bb        = []
      @bb_first_insn = []
      @bb_last_insn  = []
      @bb_succ0      = []
      @bb_succ1      = []
      @bb_idom       = []
      @bb_df_starts  = []
      @bb_df_counts  = []
      @bb_df_flat    = []
      @bb_preds_starts = []
      @bb_preds_counts = []
      @bb_preds_flat   = []
      @dom_visited     = []
      @bb_dom_children_starts = []
      @bb_dom_children_counts = []
      @bb_dom_children_flat   = []
      @hir_phi_args      = []
      @hir_rename_target = []
      @hir_bc_pc         = []
      @lir_kind          = []
      @lir_op0           = []
      @lir_op1           = []
      @lir_op2           = []
      @lir_bb            = []
      @lir_machine_code  = []
      @lir_byte_offset   = []
      @jit_bytes         = []

      # JIT-3b3: BB0 先頭にメソッドパラメータの初期 reaching def (LoadParam) を arity 個 emit。
      # rename DFS の時点で「未定義変数」エッジケースを避けるための前提セットアップ。
      arity = @method_arities[m_idx]
      ai = 0
      while ai < arity
        emit_hir(HirOp::LOAD_PARAM, ai, 0, 0)
        ai += 1
      end

      start_pc = @method_pcs[m_idx]
      end_pc   = @method_body_ends[m_idx]

      # bytecode address → hir_id の写像 (-1 = 未マップ)。
      # patch_jump の target が `@bytecode.length` (= end_pc 相当) になるケースに
      # 備えて end_pc 自身も含む長さで確保する。POP も emit_hir するので、
      # メソッド本体内のすべての jump target は必ずいずれかの hir_id にマップされる。
      bc_to_hir = []
      i = 0
      while i <= end_pc
        bc_to_hir.push(-1)
        i += 1
      end

      # 仮想スタック (各要素は SSA value 番号 = hir_id)。
      sstack = []
      # 後で target を patch する jump 命令の (hir_id, target_bc) を別配列で記録。
      pending_jump_ids     = []
      pending_jump_targets = []

      # decode_signed が @pc を進めるため一時的に借用する。VM 実行中の値は
      # build_and_dump_hir 終了時に復元する (exec_call の続行に影響させない)。
      saved_pc = @pc
      @pc = start_pc
      while @pc < end_pc
        bc_pc = @pc
        op = @bytecode[@pc]
        @pc += 1
        hir_id = -1
        if op == Op::PUSH_INT
          n = decode_signed
          hir_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::INT, n, 0)
          sstack.push(hir_id)
        elsif op == Op::PUSH_STR
          # Stage 3a: ロード対象は strlit_idx そのもの。LIR には lower しない (PUTS と同様)。
          lit_idx = decode_signed
          hir_id = emit_hir(HirOp::LOAD_STR, lit_idx, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::PUSH_TRUE
          hir_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::TRUE, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::PUSH_FALSE
          hir_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::FALSE, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::PUSH_NIL
          hir_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::NIL, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::POP
          sstack.pop
          # jump target が POP のアドレスを指すケース (中間 if + 早期 return 等)
          # に備えて HIR insn を出して bc_to_hir に登録する。
          hir_id = emit_hir(HirOp::POP, 0, 0, 0)
        elsif op == Op::STORE_LOCAL
          slot = decode_signed
          # peek (bytecode の挙動: 値は残す)。空 sstack から `nil` が混入すると
          # @hir_op1 の IntArray 推論が壊れる (spinel ルール 3) ためフェイルファスト。
          if sstack.length == 0
            raise "JIT-2 bug: STORE_LOCAL with empty sstack at pc=#{bc_pc}"
          end
          v = sstack[sstack.length - 1]
          hir_id = emit_hir(HirOp::STORE_LOCAL, slot, v, 0)
        elsif op == Op::LOAD_LOCAL
          slot = decode_signed
          hir_id = emit_hir(HirOp::LOAD_LOCAL, slot, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::JUMP
          rel = decode_signed_3
          target_bc = @pc + rel
          hir_id = emit_hir(HirOp::JUMP, -1, 0, 0)
          pending_jump_ids.push(hir_id)
          pending_jump_targets.push(target_bc)
        elsif op == Op::JUMP_IF_FALSE
          rel = decode_signed_3
          target_bc = @pc + rel
          cond = sstack.pop
          hir_id = emit_hir(HirOp::JUMP_IF_FALSE, cond, -1, 0)
          pending_jump_ids.push(hir_id)
          pending_jump_targets.push(target_bc)
        elsif op == Op::ADD
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::ADD, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::SUB
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::SUB, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::MUL
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::MUL, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::DIV
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::DIV, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::MOD
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::MOD, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::EQ
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::EQ, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::LT
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::LT, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::GT
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::GT, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::LE
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::LE, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::GE
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::GE, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::LSHIFT
          rhs = sstack.pop
          lhs = sstack.pop
          hir_id = emit_hir(HirOp::LSHIFT, lhs, rhs, 0)
          sstack.push(hir_id)
        elsif op == Op::ARRAY_NEW
          # スタック上の size 個を 1 つの ArrayNew にまとめる。要素 hir_id は CALL と
          # 同じく @hir_call_args に flat に並べる (専用配列を増やさない)。
          size = decode_signed
          if sstack.length < size
            raise "JIT-2 bug: ARRAY_NEW underflow (need #{size}, have #{sstack.length}) at pc=#{bc_pc}"
          end
          args_start = @hir_call_args.length
          ai = sstack.length - size
          ae = sstack.length
          while ai < ae
            @hir_call_args.push(sstack[ai])
            ai += 1
          end
          ai = 0
          while ai < size
            sstack.pop
            ai += 1
          end
          # op0 = size (display 用)、op1 = args_start (@hir_call_args 上の起点)、op2 = 0
          # CALL は op0=callee_idx, op1=args_start, op2=arity と分けるが、ARRAY_NEW は
          # arity 相当の値が size と同じなので op0 だけで賄い op2 は予約として 0。
          hir_id = emit_hir(HirOp::ARRAY_NEW, size, args_start, 0)
          sstack.push(hir_id)
        elsif op == Op::ARRAY_GET
          idx = sstack.pop
          arr = sstack.pop
          hir_id = emit_hir(HirOp::ARRAY_GET, arr, idx, 0)
          sstack.push(hir_id)
        elsif op == Op::ARRAY_SET
          val = sstack.pop
          idx = sstack.pop
          arr = sstack.pop
          hir_id = emit_hir(HirOp::ARRAY_SET, arr, idx, val)
          sstack.push(hir_id)   # bytecode の ARRAY_SET は val を push するのに合わせる
        elsif op == Op::ARRAY_LEN
          arr = sstack.pop
          hir_id = emit_hir(HirOp::ARRAY_LEN, arr, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::PUTS
          v = sstack.pop
          hir_id = emit_hir(HirOp::PUTS, v, 0, 0)
          # bytecode の PUTS は nil を push するのでそれに合わせる。
          nil_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::NIL, 0, 0)
          sstack.push(nil_id)
        elsif op == Op::CALL
          callee_idx = decode_signed
          arity = @method_arities[callee_idx]
          args_start = hir_collect_args(sstack, arity, "CALL", bc_pc)
          hir_id = emit_hir(HirOp::CALL, callee_idx, args_start, arity)
          sstack.push(hir_id)
        elsif op == Op::CALL_WITH_BLOCK
          # block_pc / block_arity は HIR では使わないが operand 数を合わせるためデコード。
          # LIR には lower しない (PUTS と同じ generic 経路)。
          callee_idx    = decode_signed
          _block_pc     = decode_signed
          _block_arity  = decode_signed
          arity = @method_arities[callee_idx]
          args_start = hir_collect_args(sstack, arity, "CALL_WITH_BLOCK", bc_pc)
          hir_id = emit_hir(HirOp::CALL_WITH_BLOCK, callee_idx, args_start, arity)
          sstack.push(hir_id)
        elsif op == Op::YIELD
          # Stage 3c.2: argc 個を sstack から消費し戻り値 1 値を push。
          argc = decode_signed
          args_start = hir_collect_args(sstack, argc, "YIELD", bc_pc)
          hir_id = emit_hir(HirOp::YIELD, argc, args_start, 0)
          sstack.push(hir_id)
        elsif op == Op::BLOCK_RETURN
          # Stage 3c.2: ブロック終端。VM はスタック top をそのまま保持して method 側に
          # 戻すため、HIR の sstack model も pop ではなく peek で表現する。
          # 通常 HIR builder はメソッド本体 (start_pc..end_pc) しか走査しないため、
          # ブロック領域の BLOCK_RETURN は実際には到達しないが、将来 HIR がブロック内も
          # 解析するパスで sstack 不整合を起こさないように整合させておく。
          if sstack.length == 0
            raise "JIT-2 bug: BLOCK_RETURN with empty sstack at pc=#{bc_pc}"
          end
          v = sstack[sstack.length - 1]
          hir_id = emit_hir(HirOp::BLOCK_RETURN, v, 0, 0)
        elsif op == Op::BLOCK_GIVEN_P
          # Stage 3c.3: 引数なし、bool 値 1 つを sstack に push。
          hir_id = emit_hir(HirOp::BLOCK_GIVEN_P, 0, 0, 0)
          sstack.push(hir_id)
        elsif op == Op::RETURN
          v = sstack.pop
          hir_id = emit_hir(HirOp::RETURN, v, 0, 0)
        else
          raise "JIT-2 bug: unknown opcode #{op} at pc=#{bc_pc}"
        end
        if hir_id >= 0
          bc_to_hir[bc_pc] = hir_id
          # JIT-3c: 出処 PC を記録 (pass_type_specialize での逆引きに使う)。
          @hir_bc_pc[hir_id] = bc_pc
        end
      end
      @pc = saved_pc

      # JUMP / JUMP_IF_FALSE の target を hir_id に解決する。
      pi = 0
      while pi < pending_jump_ids.length
        jhid = pending_jump_ids[pi]
        target_bc = pending_jump_targets[pi]
        target_hid = bc_to_hir[target_bc]
        if target_hid < 0
          raise "JIT-2 bug: jump target bc=#{target_bc} has no HIR mapping (m_idx=#{m_idx})"
        end
        if @hir_kind[jhid] == HirOp::JUMP
          @hir_op0[jhid] = target_hid
        else
          @hir_op1[jhid] = target_hid
        end
        pi += 1
      end

      pass_build_cfg
      build_preds_table
      init_dom_scratch
      if @dump_hir
        dump_hir(m_idx, "raw")
      end
      optimize_hir
      pass_build_dom_children
      pass_insert_phis(m_idx)
      pass_rename_vars(m_idx)
      pass_type_specialize
      if @dump_hir
        dump_hir(m_idx, "optimized")
        dump_cfg_analysis(m_idx)
      end
      pass_lower_to_lir
      pass_encode_native
      if @dump_hir
        dump_lir(m_idx)
      end
      # JIT-4c: arm64 機械語が encode できた直後に実機実行用バッファへインストール。
      # 失敗時は @jit_fn_addrs[m_idx] = -1 でマークし、以降は dispatch をスキップする。
      if @jit_exec_enabled
        install_jit_for_method(m_idx)
      end
      nil
    end

    # `@hir_bb` は emit_hir では設定しない。pass_build_cfg が後付けで全 insn に
    # 一括で割り当てる。最適化パスで insn を追加する際は @hir_bb への push も
    # 忘れないこと (将来 phi 挿入を入れる JIT-3b2 で問題になりうる)。
    # @hir_bc_pc は -1 で初期化。bytecode 走査ループが該当 hir_id を上書きする。
    # Phi/GuardFixnum など bytecode 由来でない insn は -1 のまま。
    def emit_hir(kind, op0, op1, op2)
      @hir_kind.push(kind)
      @hir_op0.push(op0)
      @hir_op1.push(op1)
      @hir_op2.push(op2)
      @hir_deleted.push(0)
      @hir_bc_pc.push(-1)
      @hir_kind.length - 1
    end

    # CALL / CALL_WITH_BLOCK / YIELD で共有: sstack 末尾 n 個を @hir_call_args に
    # コピーした上で sstack 側を pop。args_start (= 配置開始 idx) を返す。
    # underflow ガードは nil 混入による IntArray 型崩壊 (spinel ルール 3) の防止。
    def hir_collect_args(sstack, n, error_label, bc_pc)
      if sstack.length < n
        raise "JIT-2 bug: #{error_label} underflow (need #{n}, have #{sstack.length}) at pc=#{bc_pc}"
      end
      args_start = @hir_call_args.length
      ai = sstack.length - n
      ae = sstack.length
      while ai < ae
        @hir_call_args.push(sstack[ai])
        ai += 1
      end
      ai = 0
      while ai < n
        sstack.pop
        ai += 1
      end
      args_start
    end

    def dump_hir(m_idx, label)
      STDERR.puts "ZJIT HIR (#{label}) for method idx=#{m_idx}:"
      b = 0
      while b < @bb_first_insn.length
        if bb_alive_count(b) > 0
          pred_str = format_bb_preds(b)
          STDERR.puts "  BB#{b}#{pred_str}:"
          # JIT-3b3: phi insn は BB の論理的先頭にある (実際は @hir_kind の末尾に
          # append されているので、@hir_bb で BB を引いて先に表示する)。
          dump_phis_for_bb(b)
          i = @bb_first_insn[b]
          last = @bb_last_insn[b]
          while i <= last
            if @hir_deleted[i] == 0
              STDERR.puts "    v#{i} = #{format_hir_insn(i)}"
            end
            i += 1
          end
          # JIT-3c: 型特化で挿入された GuardFixnum を BB 末尾範囲外から拾って末尾表示。
          dump_guards_for_bb(b)
        end
        b += 1
      end
      nil
    end

    def dump_phis_for_bb(b)
      dump_special_for_bb(b, HirOp::PHI)
    end

    def dump_guards_for_bb(b)
      dump_special_for_bb(b, HirOp::GUARD_FIXNUM)
    end

    # phi / guard など、@bb_first_insn..@bb_last_insn 範囲外で BB 所属を @hir_bb で
    # 記録する非通常 insn を、指定 kind で BB ごとに表示するヘルパー。
    def dump_special_for_bb(b, target_kind)
      i = 0
      while i < @hir_kind.length
        if @hir_kind[i] == target_kind && @hir_bb[i] == b && @hir_deleted[i] == 0
          STDERR.puts "    v#{i} = #{format_hir_insn(i)}"
        end
        i += 1
      end
      nil
    end

    # BB 内で生きている (deleted=0) insn の数。0 ならその BB は完全に消えている。
    # PHI insn は @bb_first_insn..@bb_last_insn の範囲外 (= @hir_kind の末尾に
    # append される) なので含まない。phi だけが残る BB は現行のパス順では発生しない。
    def bb_alive_count(b)
      count = 0
      i = @bb_first_insn[b]
      last = @bb_last_insn[b]
      while i <= last
        if @hir_deleted[i] == 0
          count += 1
        end
        i += 1
      end
      count
    end

    def format_bb_preds(b)
      result = ""
      count = 0
      i = 0
      while i < @bb_first_insn.length
        if (@bb_succ0[i] == b || @bb_succ1[i] == b) && bb_alive_count(i) > 0
          if count == 0
            result = " (preds: BB" + i.to_s
          else
            result = result + ", BB" + i.to_s
          end
          count += 1
        end
        i += 1
      end
      if count > 0
        result = result + ")"
      end
      result
    end

    def format_hir_insn(i)
      kind = @hir_kind[i]
      op0  = @hir_op0[i]
      op1  = @hir_op1[i]
      op2  = @hir_op2[i]
      result = "?"
      if kind == HirOp::LOAD_CONST
        if op0 == HirConstTag::NIL
          result = "LoadConst nil"
        elsif op0 == HirConstTag::TRUE
          result = "LoadConst true"
        elsif op0 == HirConstTag::FALSE
          result = "LoadConst false"
        elsif op0 == HirConstTag::INT
          result = "LoadConst #{op1}"
        end
      elsif kind == HirOp::LOAD_LOCAL
        result = "LoadLocal slot=#{op0}"
      elsif kind == HirOp::LOAD_PARAM
        result = "LoadParam slot=#{op0}"
      elsif kind == HirOp::STORE_LOCAL
        result = "StoreLocal slot=#{op0}, v#{op1}"
      elsif kind == HirOp::POP
        result = "Pop"
      elsif kind == HirOp::PHI
        result = format_phi_insn(i)
      elsif kind == HirOp::JUMP
        result = "Jump BB#{@hir_bb[op0]}"
      elsif kind == HirOp::JUMP_IF_FALSE
        result = "JumpIfFalse v#{op0}, BB#{@hir_bb[op1]}"
      elsif kind == HirOp::ADD
        result = "Add v#{op0}, v#{op1}"
      elsif kind == HirOp::SUB
        result = "Sub v#{op0}, v#{op1}"
      elsif kind == HirOp::MUL
        result = "Mul v#{op0}, v#{op1}"
      elsif kind == HirOp::DIV
        result = "Div v#{op0}, v#{op1}"
      elsif kind == HirOp::MOD
        result = "Mod v#{op0}, v#{op1}"
      elsif kind == HirOp::EQ
        result = "Eq v#{op0}, v#{op1}"
      elsif kind == HirOp::LT
        result = "Lt v#{op0}, v#{op1}"
      elsif kind == HirOp::GT
        result = "Gt v#{op0}, v#{op1}"
      elsif kind == HirOp::LE
        result = "Le v#{op0}, v#{op1}"
      elsif kind == HirOp::GE
        result = "Ge v#{op0}, v#{op1}"
      elsif kind == HirOp::PUTS
        result = "Puts v#{op0}"
      elsif kind == HirOp::LOAD_STR
        result = "LoadStr lit=#{op0}"
      elsif kind == HirOp::LSHIFT
        result = "LShift v#{op0}, v#{op1}"
      elsif kind == HirOp::ARRAY_NEW
        result = "ArrayNew size=#{op0}"
      elsif kind == HirOp::ARRAY_GET
        result = "ArrayGet v#{op0}, v#{op1}"
      elsif kind == HirOp::ARRAY_SET
        result = "ArraySet v#{op0}, v#{op1}, v#{op2}"
      elsif kind == HirOp::ARRAY_LEN
        result = "ArrayLen v#{op0}"
      elsif kind == HirOp::CALL
        result = format_call_insn(op0, op1, op2)
      elsif kind == HirOp::CALL_WITH_BLOCK
        result = "CallWithBlock " + format_call_insn(op0, op1, op2)
      elsif kind == HirOp::YIELD
        result = format_yield_insn(op0, op1)
      elsif kind == HirOp::BLOCK_RETURN
        result = "BlockReturn v#{op0}"
      elsif kind == HirOp::BLOCK_GIVEN_P
        result = "BlockGivenP"
      elsif kind == HirOp::RETURN
        result = "Return v#{op0}"
      elsif kind == HirOp::GUARD_FIXNUM
        result = "GuardFixnum v#{op0}"
      elsif kind == HirOp::FIXNUM_ADD
        result = "FixnumAdd v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_SUB
        result = "FixnumSub v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_MUL
        result = "FixnumMul v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_DIV
        result = "FixnumDiv v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_MOD
        result = "FixnumMod v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_EQ
        result = "FixnumEq v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_LT
        result = "FixnumLt v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_GT
        result = "FixnumGt v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_LE
        result = "FixnumLe v#{op0}, v#{op1}"
      elsif kind == HirOp::FIXNUM_GE
        result = "FixnumGe v#{op0}, v#{op1}"
      end
      result
    end

    def format_call_insn(callee_idx, args_start, arity)
      result = "Call m#{callee_idx}("
      ci = 0
      while ci < arity
        if ci > 0
          result = result + ", "
        end
        arg_hid = @hir_call_args[args_start + ci]
        result = result + "v#{arg_hid}"
        ci += 1
      end
      result = result + ")"
      result
    end

    def format_yield_insn(argc, args_start)
      result = "Yield("
      ci = 0
      while ci < argc
        if ci > 0
          result = result + ", "
        end
        arg_hid = @hir_call_args[args_start + ci]
        result = result + "v#{arg_hid}"
        ci += 1
      end
      result = result + ")"
      result
    end

    # ============================================================
    # JIT-3a: HIR 最適化パス
    # ============================================================

    def optimize_hir
      pass_fold_constants
      pass_eliminate_dead_code
      pass_clean_cfg
      pass_compute_dominators
      pass_compute_df
      nil
    end

    # 二項算術 (ADD/SUB/MUL/DIV/MOD) と二項比較 (EQ/LT/GT/LE/GE) で両オペランドが
    # LOAD_CONST(INT) なら定数畳み込みする。DIV/MOD は rhs=0 のときのみ畳まずに
    # 残す (VM の ZeroDivisionError と挙動を一致させるため)。畳まれた DIV/MOD は
    # LOAD_CONST に in-place で書き換えられ、has_side_effect の DIV/MOD ガードは
    # 「畳まれずに残った」DIV/MOD insn を eliminate_dead_code から守るためのもの。
    def pass_fold_constants
      i = 0
      while i < @hir_kind.length
        if @hir_deleted[i] == 0
          kind = @hir_kind[i]
          if arith_kind?(kind) || compare_kind?(kind)
            try_fold_binop(i, kind)
          end
        end
        i += 1
      end
      nil
    end

    def arith_kind?(kind)
      kind >= HirOp::ADD && kind <= HirOp::MOD
    end

    def compare_kind?(kind)
      kind >= HirOp::EQ && kind <= HirOp::GE
    end

    def fixnum_arith_kind?(kind)
      kind >= HirOp::FIXNUM_ADD && kind <= HirOp::FIXNUM_MOD
    end

    def fixnum_compare_kind?(kind)
      kind >= HirOp::FIXNUM_EQ && kind <= HirOp::FIXNUM_GE
    end

    # 二項算術/比較 (op0 = lhs, op1 = rhs の use パターン) の統合述語。
    # accumulate_uses / apply_rename_targets が将来の特化命令追加でも壊れないようまとめる。
    # LSHIFT も op0/op1 が値の二項演算なので含める (kind 番号は離れているが意味的に同じ)。
    # 注: pass_fold_constants の対象は arith_kind? || compare_kind? のみで、LSHIFT は
    # 文字列/配列のヒープ操作なので畳み込み対象ではない。
    def binop_kind?(kind)
      arith_kind?(kind) || compare_kind?(kind) ||
        fixnum_arith_kind?(kind) || fixnum_compare_kind?(kind) ||
        kind == HirOp::LSHIFT
    end

    def try_fold_binop(i, kind)
      lhs_id = @hir_op0[i]
      rhs_id = @hir_op1[i]
      if !const_int?(lhs_id) || !const_int?(rhs_id)
        return nil
      end
      a = @hir_op1[lhs_id]
      b = @hir_op1[rhs_id]
      if kind == HirOp::DIV || kind == HirOp::MOD
        if b == 0
          return nil
        end
      end
      if arith_kind?(kind)
        v = eval_arith(kind, a, b)
        @hir_kind[i] = HirOp::LOAD_CONST
        @hir_op0[i]  = HirConstTag::INT
        @hir_op1[i]  = v
        @hir_op2[i]  = 0
      else
        tag = eval_compare(kind, a, b)
        @hir_kind[i] = HirOp::LOAD_CONST
        @hir_op0[i]  = tag
        @hir_op1[i]  = 0
        @hir_op2[i]  = 0
      end
      nil
    end

    # `@hir_deleted == 0` チェックは現行のパス順 (fold → eliminate_dead_code)
    # では redundant だが、将来パスの順序が変わったときの防衛として残す。
    def const_int?(hir_id)
      @hir_kind[hir_id] == HirOp::LOAD_CONST &&
        @hir_op0[hir_id] == HirConstTag::INT &&
        @hir_deleted[hir_id] == 0
    end

    def eval_arith(kind, a, b)
      r = 0
      if kind == HirOp::ADD
        r = a + b
      elsif kind == HirOp::SUB
        r = a - b
      elsif kind == HirOp::MUL
        r = a * b
      elsif kind == HirOp::DIV
        r = a / b
      elsif kind == HirOp::MOD
        r = a % b
      end
      r
    end

    def eval_compare(kind, a, b)
      result = HirConstTag::FALSE
      if kind == HirOp::EQ
        if a == b
          result = HirConstTag::TRUE
        end
      elsif kind == HirOp::LT
        if a < b
          result = HirConstTag::TRUE
        end
      elsif kind == HirOp::GT
        if a > b
          result = HirConstTag::TRUE
        end
      elsif kind == HirOp::LE
        if a <= b
          result = HirConstTag::TRUE
        end
      elsif kind == HirOp::GE
        if a >= b
          result = HirConstTag::TRUE
        end
      end
      result
    end

    # 副作用なし & どこからも参照されていない insn を deleted=1 にする。
    # JUMP/JUMP_IF_FALSE の target も use として数えるので、jump 先の insn が
    # 誤って削除されることはない (副作用判定だけでは LoadLocal/LoadConst が
    # 落ちる可能性があるが、use 数で守られる)。
    def pass_eliminate_dead_code
      use_counts = []
      i = 0
      while i < @hir_kind.length
        use_counts.push(0)
        i += 1
      end
      i = 0
      while i < @hir_kind.length
        if @hir_deleted[i] == 0
          accumulate_uses(i, use_counts)
        end
        i += 1
      end
      i = 0
      while i < @hir_kind.length
        if @hir_deleted[i] == 0 && !side_effect?(@hir_kind[i]) && use_counts[i] == 0
          @hir_deleted[i] = 1
        end
        i += 1
      end
      nil
    end

    def accumulate_uses(i, use_counts)
      kind = @hir_kind[i]
      if kind == HirOp::STORE_LOCAL
        use_counts[@hir_op1[i]] += 1
      elsif kind == HirOp::JUMP
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::JUMP_IF_FALSE
        use_counts[@hir_op0[i]] += 1
        use_counts[@hir_op1[i]] += 1
      elsif binop_kind?(kind)
        use_counts[@hir_op0[i]] += 1
        use_counts[@hir_op1[i]] += 1
      elsif kind == HirOp::ARRAY_NEW
        # 要素 hir_id を @hir_call_args 上に flat 格納 (op0=size, op1=args_start)
        size       = @hir_op0[i]
        args_start = @hir_op1[i]
        j = 0
        while j < size
          use_counts[@hir_call_args[args_start + j]] += 1
          j += 1
        end
      elsif kind == HirOp::ARRAY_GET || kind == HirOp::ARRAY_LEN
        use_counts[@hir_op0[i]] += 1
        if kind == HirOp::ARRAY_GET
          use_counts[@hir_op1[i]] += 1
        end
      elsif kind == HirOp::ARRAY_SET
        use_counts[@hir_op0[i]] += 1
        use_counts[@hir_op1[i]] += 1
        use_counts[@hir_op2[i]] += 1
      elsif kind == HirOp::GUARD_FIXNUM
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::PUTS
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::CALL || kind == HirOp::CALL_WITH_BLOCK
        # 引数並びは @hir_call_args 上、op1=args_start, op2=arity の規約を共有。
        args_start = @hir_op1[i]
        arity      = @hir_op2[i]
        j = 0
        while j < arity
          use_counts[@hir_call_args[args_start + j]] += 1
          j += 1
        end
      elsif kind == HirOp::YIELD
        argc       = @hir_op0[i]
        args_start = @hir_op1[i]
        j = 0
        while j < argc
          use_counts[@hir_call_args[args_start + j]] += 1
          j += 1
        end
      elsif kind == HirOp::BLOCK_RETURN
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::RETURN
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::PHI
        args_start = @hir_op1[i]
        arity      = @hir_op2[i]
        j = 0
        while j < arity
          v = @hir_phi_args[args_start + j]
          if v >= 0
            use_counts[v] += 1
          end
          j += 1
        end
      end
      # LOAD_CONST / LOAD_LOCAL / LOAD_PARAM / POP は op が即値またはなしなので加算不要。
      nil
    end

    # 副作用あり = 削除すると意味論が壊れる kind。LOAD_CONST/LOAD_LOCAL や
    # 算術/比較は use 0 なら落としてよい (= 副作用なし)。
    # DIV/MOD は折り畳まれずに残ったときゼロ除算で raise しうるので副作用あり扱い。
    def side_effect?(kind)
      result = false
      if kind == HirOp::STORE_LOCAL
        result = true
      elsif kind == HirOp::POP
        result = true
      elsif kind == HirOp::JUMP
        result = true
      elsif kind == HirOp::JUMP_IF_FALSE
        result = true
      elsif kind == HirOp::PUTS
        result = true
      elsif kind == HirOp::CALL
        result = true
      elsif kind == HirOp::RETURN
        result = true
      elsif kind == HirOp::DIV
        result = true   # ゼロ除算で raise しうる
      elsif kind == HirOp::MOD
        result = true
      elsif kind == HirOp::LOAD_PARAM
        result = true   # 直接 use がなくても reaching def の起点なので削除しない
      elsif kind == HirOp::PHI
        result = true   # 現行のパス順では DCE は phi 挿入前だが、将来順序が変わっても誤削除されないよう保護
      elsif kind == HirOp::GUARD_FIXNUM
        result = true   # side exit を起こすので削除しない
      elsif kind == HirOp::FIXNUM_DIV
        result = true   # ゼロ除算で raise しうる
      elsif kind == HirOp::FIXNUM_MOD
        result = true
      elsif kind == HirOp::LSHIFT
        result = true   # ヒープ String/Array を in-place ミューテーションするため除去禁止
      elsif kind == HirOp::ARRAY_SET
        result = true   # in-place 書き込み
      elsif kind == HirOp::ARRAY_GET
        result = true   # 範囲外 / 型違いで raise しうる
      elsif kind == HirOp::ARRAY_LEN
        result = true   # 型違いで raise しうる
      elsif kind == HirOp::ARRAY_NEW
        result = true   # 観察可能なヒープ確保 (slot idx が外部状態に効く)
      elsif kind == HirOp::CALL_WITH_BLOCK
        result = true
      elsif kind == HirOp::YIELD
        result = true   # block 経由で IO/状態変更しうる
      elsif kind == HirOp::BLOCK_RETURN
        result = true   # 制御フロー終端
      end
      result
    end

    # ============================================================
    # JIT-3b1: CFG (basic block) 構築 + clean_cfg
    # ============================================================

    # メソッド先頭 / jump target / jump-or-return の直後で BB を切る。
    # 各 insn を BB に割り当て、各 BB の (first_insn, last_insn, succ0, succ1) を確定する。
    # CFG 構造は後段で書き換わらない (fold_constants は kind を LOAD_CONST に変えるが
    # JUMP/JUMP_IF_FALSE/RETURN は変えない、また pass_eliminate_dead_code は
    # side_effect? が JUMP/JUMP_IF_FALSE/RETURN を保護するので削除されない)
    # ので、build_and_dump_hir で 1 度だけ呼ぶ。
    def pass_build_cfg
      n = @hir_kind.length
      if n == 0
        return nil
      end
      is_bb_start = []
      i = 0
      while i < n
        is_bb_start.push(0)
        i += 1
      end
      is_bb_start[0] = 1
      i = 0
      while i < n
        k = @hir_kind[i]
        if k == HirOp::JUMP
          is_bb_start[@hir_op0[i]] = 1
          if i + 1 < n
            is_bb_start[i + 1] = 1
          end
        elsif k == HirOp::JUMP_IF_FALSE
          is_bb_start[@hir_op1[i]] = 1
          if i + 1 < n
            is_bb_start[i + 1] = 1
          end
        elsif k == HirOp::RETURN || k == HirOp::BLOCK_RETURN
          if i + 1 < n
            is_bb_start[i + 1] = 1
          end
        end
        i += 1
      end
      current_bb = -1
      i = 0
      while i < n
        if is_bb_start[i] == 1
          if current_bb >= 0
            @bb_last_insn[current_bb] = i - 1
          end
          current_bb = @bb_first_insn.length
          @bb_first_insn.push(i)
          @bb_last_insn.push(i)
        end
        @hir_bb.push(current_bb)
        i += 1
      end
      if current_bb >= 0
        @bb_last_insn[current_bb] = n - 1
      end
      # 後継を確定する。
      # - JUMP:           succ0 = jump target、succ1 = -1
      # - JUMP_IF_FALSE:  succ0 = 偽分岐 (= jump target、@hir_op1)、succ1 = 真分岐 (fallthrough)
      # - RETURN:         succ0 = succ1 = -1
      # - その他の終端 (フォールスルー): succ0 = next BB、succ1 = -1
      b = 0
      while b < @bb_first_insn.length
        last = @bb_last_insn[b]
        k = @hir_kind[last]
        if k == HirOp::JUMP
          @bb_succ0.push(@hir_bb[@hir_op0[last]])
          @bb_succ1.push(-1)
        elsif k == HirOp::JUMP_IF_FALSE
          @bb_succ0.push(@hir_bb[@hir_op1[last]])
          if last + 1 < n
            @bb_succ1.push(@hir_bb[last + 1])
          else
            # 現行 compiler では JUMP_IF_FALSE の後には必ず then ブロックか PUSH_NIL が続く。
            # この raise は将来コード生成パターンが拡張されたときの早期検出用。
            raise "CFG bug: JUMP_IF_FALSE at HIR tail (id=#{last}), fallthrough BB missing"
          end
        elsif k == HirOp::RETURN || k == HirOp::BLOCK_RETURN
          @bb_succ0.push(-1)
          @bb_succ1.push(-1)
        else
          if last + 1 < n
            @bb_succ0.push(@hir_bb[last + 1])
          else
            @bb_succ0.push(-1)
          end
          @bb_succ1.push(-1)
        end
        b += 1
      end
      nil
    end

    # BB0 (エントリ) から BFS で到達可能な BB を列挙し、未到達 BB の insn を deleted=1 に。
    # queue は先頭インデックスを進めるだけの単純実装 (shift 不使用、IntArray 親和)。
    def pass_clean_cfg
      nbb = @bb_first_insn.length
      if nbb == 0
        return nil
      end
      visited = []
      i = 0
      while i < nbb
        visited.push(0)
        i += 1
      end
      queue = []
      queue.push(0)
      visited[0] = 1
      qhead = 0
      while qhead < queue.length
        b = queue[qhead]
        qhead += 1
        s0 = @bb_succ0[b]
        if s0 >= 0 && visited[s0] == 0
          visited[s0] = 1
          queue.push(s0)
        end
        s1 = @bb_succ1[b]
        if s1 >= 0 && visited[s1] == 0
          visited[s1] = 1
          queue.push(s1)
        end
      end
      b = 0
      while b < nbb
        if visited[b] == 0
          j    = @bb_first_insn[b]
          last = @bb_last_insn[b]
          while j <= last
            @hir_deleted[j] = 1
            j += 1
          end
        end
        b += 1
      end
      nil
    end

    # ============================================================
    # JIT-3b2: dominator tree + dominance frontier
    # ============================================================

    # CFG 構築直後に各 BB の predecessor を SoA で集計する。pass_compute_dominators
    # と pass_compute_df が共通参照する (build_and_dump_hir で 1 度だけ呼ぶ)。
    def build_preds_table
      nbb = @bb_first_insn.length
      b = 0
      while b < nbb
        @bb_preds_starts.push(@bb_preds_flat.length)
        cnt = 0
        p = 0
        while p < nbb
          if @bb_succ0[p] == b || @bb_succ1[p] == b
            @bb_preds_flat.push(p)
            cnt += 1
          end
          p += 1
        end
        @bb_preds_counts.push(cnt)
        b += 1
      end
      nil
    end

    # dom_intersect が再利用するスクラッチ配列を nbb 個 0 で確保する。
    def init_dom_scratch
      nbb = @bb_first_insn.length
      i = 0
      while i < nbb
        @dom_visited.push(0)
        i += 1
      end
      nil
    end

    # Cooper et al. の "A Simple, Fast Dominance Algorithm" の素朴反復版。
    # BB 数が小さいので O(N^3) 程度でも問題ない。reverse postorder ではなく
    # 単純に BB id 昇順で走査し、idom が変化しなくなるまで繰り返す。
    # 到達不能 BB (clean_cfg で全 insn が deleted のもの) は idom = -1 のまま残す。
    def pass_compute_dominators
      nbb = @bb_first_insn.length
      i = 0
      while i < nbb
        @bb_idom.push(-1)
        i += 1
      end
      if nbb == 0
        return nil
      end
      @bb_idom[0] = 0
      changed = 1
      while changed != 0
        changed = 0
        b = 1
        while b < nbb
          if bb_alive_count(b) > 0
            new_idom = compute_new_idom(b)
            if new_idom != -1 && @bb_idom[b] != new_idom
              @bb_idom[b] = new_idom
              changed = 1
            end
          end
          b += 1
        end
      end
      nil
    end

    def compute_new_idom(b)
      result = -1
      pi = 0
      pcount = @bb_preds_counts[b]
      pstart = @bb_preds_starts[b]
      while pi < pcount
        p = @bb_preds_flat[pstart + pi]
        if @bb_idom[p] != -1
          if result == -1
            result = p
          else
            result = dom_intersect(result, p)
          end
        end
        pi += 1
      end
      result
    end

    # b1, b2 の共通 dominator を求める。b1 のチェーンを @dom_visited に記録し、
    # b2 のチェーンを遡って最初に visited な BB を返す。
    # idom が -1 のチェーンに当たったら早期 return (収束途中の状態、次の iter
    # で再評価される)。
    def dom_intersect(b1, b2)
      nbb = @bb_first_insn.length
      i = 0
      while i < nbb
        @dom_visited[i] = 0
        i += 1
      end
      cur = b1
      @dom_visited[cur] = 1
      parent = @bb_idom[cur]
      while parent != cur && parent != -1
        cur = parent
        @dom_visited[cur] = 1
        parent = @bb_idom[cur]
      end
      cur = b2
      while @dom_visited[cur] == 0
        parent = @bb_idom[cur]
        if parent == cur || parent == -1
          return cur
        end
        cur = parent
      end
      cur
    end

    # Cytron らの DF 計算。各合流点 b について、各 pred p から b の idom まで
    # 遡る間の各 BB に b を DF として記録する。preds テーブルは build_preds_table
    # が事前に @bb_preds_* に格納済み。
    def pass_compute_df
      nbb = @bb_first_insn.length
      if nbb == 0
        return nil
      end
      # 合流点判定 + 各 BB が他 BB の DF に含まれるかをフラグ matrix で集計。
      is_df = []
      i = 0
      total = nbb * nbb
      while i < total
        is_df.push(0)
        i += 1
      end
      b = 0
      while b < nbb
        if @bb_preds_counts[b] >= 2 && @bb_idom[b] != -1
          pi = 0
          while pi < @bb_preds_counts[b]
            p = @bb_preds_flat[@bb_preds_starts[b] + pi]
            # unreachable pred (clean_cfg で削除された BB) は idom=-1 のままで
            # 走査すると `is_df[dead_bb * nbb + b]` に誤って書き込まれて、JIT-3b3 で
            # phi 配置を狂わせる。pred ループ入口でガードする。
            if @bb_idom[p] != -1
              runner = p
              while runner != @bb_idom[b] && runner != -1
                is_df[runner * nbb + b] = 1
                parent = @bb_idom[runner]
                if parent == runner || parent == -1
                  runner = -1
                else
                  runner = parent
                end
              end
            end
            pi += 1
          end
        end
        b += 1
      end
      # フラグ matrix を SoA flat に変換。
      b = 0
      while b < nbb
        @bb_df_starts.push(@bb_df_flat.length)
        cnt = 0
        y = 0
        while y < nbb
          if is_df[b * nbb + y] == 1
            @bb_df_flat.push(y)
            cnt += 1
          end
          y += 1
        end
        @bb_df_counts.push(cnt)
        b += 1
      end
      nil
    end

    def dump_cfg_analysis(m_idx)
      STDERR.puts "ZJIT CFG analysis for method idx=#{m_idx}:"
      b = 0
      while b < @bb_first_insn.length
        if bb_alive_count(b) > 0
          idom_str = format_bb_idom(b)
          df_str   = format_bb_df(b)
          STDERR.puts "  BB#{b}: idom=#{idom_str}, DF={#{df_str}}"
        end
        b += 1
      end
      nil
    end

    def format_bb_idom(b)
      result = "?"
      ib = @bb_idom[b]
      if ib >= 0
        result = "BB" + ib.to_s
      end
      result
    end

    def format_bb_df(b)
      result = ""
      start = @bb_df_starts[b]
      count = @bb_df_counts[b]
      i = 0
      while i < count
        if i > 0
          result = result + ", "
        end
        result = result + "BB" + @bb_df_flat[start + i].to_s
        i += 1
      end
      result
    end

    def format_phi_insn(i)
      slot = @hir_op0[i]
      args_start = @hir_op1[i]
      arity = @hir_op2[i]
      bb = @hir_bb[i]
      result = "Phi slot=" + slot.to_s + " ["
      pred_start = @bb_preds_starts[bb]
      ai = 0
      while ai < arity
        if ai > 0
          result = result + ", "
        end
        pred_bb = @bb_preds_flat[pred_start + ai]
        val = @hir_phi_args[args_start + ai]
        result = result + "BB" + pred_bb.to_s + " -> v" + val.to_s
        ai += 1
      end
      result = result + "]"
      result
    end

    # ============================================================
    # JIT-3b3: phi 挿入 + variable renaming (Cytron アルゴリズム)
    # ============================================================

    # 各 BB について dominator tree の子 BB を SoA で集める。rename DFS で使う。
    def pass_build_dom_children
      nbb = @bb_first_insn.length
      b = 0
      while b < nbb
        @bb_dom_children_starts.push(@bb_dom_children_flat.length)
        cnt = 0
        c = 1   # BB0 は root なので親を持たない (idom[0] = 0 = 自分)
        while c < nbb
          if @bb_idom[c] == b && c != b
            @bb_dom_children_flat.push(c)
            cnt += 1
          end
          c += 1
        end
        @bb_dom_children_counts.push(cnt)
        b += 1
      end
      nil
    end

    # 各ローカル変数 (slot) の def 集合に対して worklist で DF を辿り、合流点に phi 挿入。
    # parameter は BB0 で定義されたとみなす (= LoadParam があるため has_def[0] = 1)。
    def pass_insert_phis(m_idx)
      num_slots = @method_local_counts[m_idx]
      arity     = @method_arities[m_idx]
      nbb = @bb_first_insn.length
      if nbb == 0 || num_slots == 0
        return nil
      end
      phi_at_bb = []
      i = 0
      total = nbb * num_slots
      while i < total
        phi_at_bb.push(-1)
        i += 1
      end
      slot = 0
      while slot < num_slots
        has_def = []
        i = 0
        while i < nbb
          has_def.push(0)
          i += 1
        end
        # パラメータ (slot < arity) は BB0 先頭で LoadParam として定義済み。
        # それ以外のローカル変数は STORE_LOCAL を通じてのみ定義され、BB0 に
        # 自動的な def はない。
        if slot < arity
          has_def[0] = 1
        end
        i = 0
        n = @hir_kind.length
        while i < n
          if @hir_deleted[i] == 0 && @hir_kind[i] == HirOp::STORE_LOCAL && @hir_op0[i] == slot
            has_def[@hir_bb[i]] = 1
          end
          i += 1
        end
        worklist = []
        i = 0
        while i < nbb
          if has_def[i] == 1
            worklist.push(i)
          end
          i += 1
        end
        qhead = 0
        while qhead < worklist.length
          b = worklist[qhead]
          qhead += 1
          df_start = @bb_df_starts[b]
          df_count = @bb_df_counts[b]
          di = 0
          while di < df_count
            y = @bb_df_flat[df_start + di]
            if phi_at_bb[y * num_slots + slot] < 0 && bb_alive_count(y) > 0
              phi_arity = @bb_preds_counts[y]
              args_start = @hir_phi_args.length
              ai = 0
              while ai < phi_arity
                @hir_phi_args.push(-1)   # rename で確定する
                ai += 1
              end
              phi_id = emit_phi_at(y, slot, args_start, phi_arity)
              phi_at_bb[y * num_slots + slot] = phi_id
              if has_def[y] == 0
                has_def[y] = 1
                worklist.push(y)
              end
            end
            di += 1
          end
        end
        slot += 1
      end
      nil
    end

    # 注: @hir_rename_target はここで push しない。pass_rename_vars 冒頭で
    # @hir_kind.length 個まとめて push される設計のため。pass_insert_phis →
    # pass_rename_vars の順序が前提。順序を変える場合はここで push も必要。
    def emit_phi_at(bb, slot, args_start, arity)
      @hir_kind.push(HirOp::PHI)
      @hir_op0.push(slot)
      @hir_op1.push(args_start)
      @hir_op2.push(arity)
      @hir_deleted.push(0)
      @hir_bb.push(bb)
      @hir_bc_pc.push(-1)
      @hir_kind.length - 1
    end

    # dominator tree の DFS で reaching def stack を維持し、LOAD_LOCAL/STORE_LOCAL を
    # SSA value に書き換える (Cytron rename)。LOAD_LOCAL は @hir_rename_target で
    # reaching def hir_id にリダイレクトし、最後に apply_rename_targets で全 use を置換。
    def pass_rename_vars(m_idx)
      num_slots = @method_local_counts[m_idx]
      nbb = @bb_first_insn.length
      if nbb == 0 || num_slots == 0
        return nil
      end
      n = @hir_kind.length
      i = 0
      while i < n
        @hir_rename_target.push(i)
        i += 1
      end
      reaching_top = []
      i = 0
      while i < num_slots
        reaching_top.push(-1)
        i += 1
      end
      saved_stack = []
      rename_bb_visit(0, num_slots, reaching_top, saved_stack)
      apply_rename_targets
      nil
    end

    def rename_bb_visit(b, num_slots, reaching_top, saved_stack)
      mark = saved_stack.length
      # 1. この BB の phi (= def) を reaching_top に push
      i = 0
      n = @hir_kind.length
      while i < n
        if @hir_bb[i] == b && @hir_kind[i] == HirOp::PHI && @hir_deleted[i] == 0
          slot = @hir_op0[i]
          saved_stack.push(slot)
          saved_stack.push(reaching_top[slot])
          reaching_top[slot] = i
        end
        i += 1
      end
      # 2. 通常 insn を順に処理
      i = @bb_first_insn[b]
      last = @bb_last_insn[b]
      while i <= last
        if @hir_deleted[i] == 0
          kind = @hir_kind[i]
          if kind == HirOp::LOAD_PARAM
            slot = @hir_op0[i]
            saved_stack.push(slot)
            saved_stack.push(reaching_top[slot])
            reaching_top[slot] = i
          elsif kind == HirOp::LOAD_LOCAL
            slot = @hir_op0[i]
            @hir_rename_target[i] = reaching_top[slot]
            @hir_deleted[i] = 1
          elsif kind == HirOp::STORE_LOCAL
            slot = @hir_op0[i]
            v = resolve_rename(@hir_op1[i])
            saved_stack.push(slot)
            saved_stack.push(reaching_top[slot])
            reaching_top[slot] = v
            @hir_deleted[i] = 1
          end
        end
        i += 1
      end
      # 3. 後継の phi に args を埋める
      s0 = @bb_succ0[b]
      if s0 >= 0
        fill_phi_args_for_succ(b, s0, reaching_top)
      end
      s1 = @bb_succ1[b]
      if s1 >= 0
        fill_phi_args_for_succ(b, s1, reaching_top)
      end
      # 4. dominator tree の子を再帰
      ds = @bb_dom_children_starts[b]
      dc = @bb_dom_children_counts[b]
      di = 0
      while di < dc
        child = @bb_dom_children_flat[ds + di]
        rename_bb_visit(child, num_slots, reaching_top, saved_stack)
        di += 1
      end
      # 5. この BB で push した分を pop
      while saved_stack.length > mark
        prev_value = saved_stack.pop
        slot = saved_stack.pop
        reaching_top[slot] = prev_value
      end
      nil
    end

    def fill_phi_args_for_succ(from_bb, to_bb, reaching_top)
      pred_start = @bb_preds_starts[to_bb]
      pred_count = @bb_preds_counts[to_bb]
      # build_preds_table は同一 from_bb を 1 度しか push しないが、最初の
      # 一致で打ち切ると将来 CFG 構築が変わって複数 push になっても安全。
      idx = -1
      pi = 0
      while pi < pred_count && idx < 0
        if @bb_preds_flat[pred_start + pi] == from_bb
          idx = pi
        end
        pi += 1
      end
      if idx < 0
        return nil
      end
      i = 0
      n = @hir_kind.length
      while i < n
        if @hir_bb[i] == to_bb && @hir_kind[i] == HirOp::PHI && @hir_deleted[i] == 0
          slot = @hir_op0[i]
          args_start = @hir_op1[i]
          @hir_phi_args[args_start + idx] = reaching_top[slot]
        end
        i += 1
      end
      nil
    end

    # rename_target を辿って最終 def に解決 (path compression なしの素朴版)。
    def resolve_rename(h)
      if h < 0
        return h
      end
      cur = h
      while @hir_rename_target[cur] != cur
        cur = @hir_rename_target[cur]
      end
      cur
    end

    # 全 use を rename_target で書き換える。LOAD_LOCAL の hir_id を参照していた箇所が
    # その reaching def hir_id に置換される。
    # 注: HirOp::GUARD_FIXNUM / FIXNUM_* は pass_type_specialize で emit されるが、
    # それは pass_rename_vars (= apply_rename_targets) より後なのでここでは扱わない。
    # specialize_binop が emit_guard_fixnum_at に渡す lhs/rhs は既に rename 済み。
    # pass 順を変える場合は GUARD_FIXNUM / FIXNUM_* の use 書き換えもここで必要。
    def apply_rename_targets
      i = 0
      n = @hir_kind.length
      while i < n
        kind = @hir_kind[i]
        if kind == HirOp::JUMP_IF_FALSE
          @hir_op0[i] = resolve_rename(@hir_op0[i])
        elsif binop_kind?(kind)
          @hir_op0[i] = resolve_rename(@hir_op0[i])
          @hir_op1[i] = resolve_rename(@hir_op1[i])
        elsif kind == HirOp::ARRAY_NEW
          # @hir_call_args 上をリダイレクト (op0=size, op1=args_start)
          size       = @hir_op0[i]
          args_start = @hir_op1[i]
          ai = 0
          while ai < size
            @hir_call_args[args_start + ai] = resolve_rename(@hir_call_args[args_start + ai])
            ai += 1
          end
        elsif kind == HirOp::ARRAY_GET
          @hir_op0[i] = resolve_rename(@hir_op0[i])
          @hir_op1[i] = resolve_rename(@hir_op1[i])
        elsif kind == HirOp::ARRAY_SET
          @hir_op0[i] = resolve_rename(@hir_op0[i])
          @hir_op1[i] = resolve_rename(@hir_op1[i])
          @hir_op2[i] = resolve_rename(@hir_op2[i])
        elsif kind == HirOp::ARRAY_LEN
          @hir_op0[i] = resolve_rename(@hir_op0[i])
        elsif kind == HirOp::PUTS
          @hir_op0[i] = resolve_rename(@hir_op0[i])
        elsif kind == HirOp::CALL || kind == HirOp::CALL_WITH_BLOCK
          args_start = @hir_op1[i]
          arity      = @hir_op2[i]
          ai = 0
          while ai < arity
            @hir_call_args[args_start + ai] = resolve_rename(@hir_call_args[args_start + ai])
            ai += 1
          end
        elsif kind == HirOp::YIELD
          argc       = @hir_op0[i]
          args_start = @hir_op1[i]
          ai = 0
          while ai < argc
            @hir_call_args[args_start + ai] = resolve_rename(@hir_call_args[args_start + ai])
            ai += 1
          end
        elsif kind == HirOp::BLOCK_RETURN
          @hir_op0[i] = resolve_rename(@hir_op0[i])
        elsif kind == HirOp::RETURN
          @hir_op0[i] = resolve_rename(@hir_op0[i])
        elsif kind == HirOp::PHI
          args_start = @hir_op1[i]
          arity      = @hir_op2[i]
          ai = 0
          while ai < arity
            v = @hir_phi_args[args_start + ai]
            if v >= 0
              @hir_phi_args[args_start + ai] = resolve_rename(v)
            end
            ai += 1
          end
        end
        i += 1
      end
      nil
    end

    # ============================================================
    # JIT-3c: type_specialize (Fixnum 特化 + GuardFixnum 挿入)
    # ============================================================

    # 各 ADD/SUB/MUL/DIV/MOD/EQ/LT/GT/LE/GE 命令について、対応する bytecode PC が
    # @profile_fixnum_pc で観測されていれば Fixnum 特化版に kind 変更し、両 op に
    # GuardFixnum を 1 個ずつ挿入。GuardFixnum は @hir_kind 末尾に append され
    # @hir_bb で論理 BB を持つ (phi と同じ非通常 insn パターン)。
    def pass_type_specialize
      n_initial = @hir_kind.length
      i = 0
      while i < n_initial
        if @hir_deleted[i] == 0
          kind = @hir_kind[i]
          if arith_kind?(kind) || compare_kind?(kind)
            bc_pc = @hir_bc_pc[i]
            if bc_pc >= 0 && @profile_fixnum_pc[bc_pc] == 1
              specialize_binop(i, kind)
            end
          end
        end
        i += 1
      end
      nil
    end

    def specialize_binop(i, kind)
      bb = @hir_bb[i]
      lhs = @hir_op0[i]
      rhs = @hir_op1[i]
      # GUARD_FIXNUM は side effect (TBZ + side exit) のみで値を生成しない。
      # 旧実装は FIXNUM_ADD の op0/op1 を guard の hir_id に向けていたが、LIR lowering で
      # hir_to_reg(guard) が未初期化 register になり実機実行時に誤った値が出る。
      # binop の op0/op1 は元の lhs/rhs を指すように修正、guard は副作用 insn として
      # 別途 emit (ダンプ上は「先行 TBZ」として表示される)。
      emit_guard_fixnum_at(bb, lhs)
      emit_guard_fixnum_at(bb, rhs)
      @hir_kind[i] = fixnum_kind_for(kind)
      nil
    end

    def emit_guard_fixnum_at(bb, value_hir_id)
      @hir_kind.push(HirOp::GUARD_FIXNUM)
      @hir_op0.push(value_hir_id)
      @hir_op1.push(0)
      @hir_op2.push(0)
      @hir_deleted.push(0)
      @hir_bb.push(bb)
      @hir_bc_pc.push(-1)
      @hir_kind.length - 1
    end

    def fixnum_kind_for(kind)
      result = kind
      if kind == HirOp::ADD
        result = HirOp::FIXNUM_ADD
      elsif kind == HirOp::SUB
        result = HirOp::FIXNUM_SUB
      elsif kind == HirOp::MUL
        result = HirOp::FIXNUM_MUL
      elsif kind == HirOp::DIV
        result = HirOp::FIXNUM_DIV
      elsif kind == HirOp::MOD
        result = HirOp::FIXNUM_MOD
      elsif kind == HirOp::EQ
        result = HirOp::FIXNUM_EQ
      elsif kind == HirOp::LT
        result = HirOp::FIXNUM_LT
      elsif kind == HirOp::GT
        result = HirOp::FIXNUM_GT
      elsif kind == HirOp::LE
        result = HirOp::FIXNUM_LE
      elsif kind == HirOp::GE
        result = HirOp::FIXNUM_GE
      end
      result
    end

    # ============================================================
    # JIT-4 (案 A): HIR → LIR lowering + arm64 エンコーダ + ダンプ
    # ============================================================
    # 実機実行はしない。SSA HIR を低レベル中間表現に下げ、各 LIR insn を
    # 32bit arm64 機械語にエンコードして「アセンブリ + hex」をダンプするのみ。
    # レジスタ割り当ては素朴 (hir_id → x9..x28 の循環)、衝突は無視。
    # critical edge split は行わないため while loop 等で phi のコピーは
    # 厳密には正しくないが、構造は読み取れる教育用の最小実装。

    def hir_to_reg(hir_id)
      9 + (hir_id % 20)
    end

    def emit_lir(kind, op0, op1, op2, bb)
      @lir_kind.push(kind)
      @lir_op0.push(op0)
      @lir_op1.push(op1)
      @lir_op2.push(op2)
      @lir_bb.push(bb)
      @lir_kind.length - 1
    end

    def pass_lower_to_lir
      b = 0
      while b < @bb_first_insn.length
        if bb_alive_count(b) > 0
          lower_bb(b)
        end
        b += 1
      end
      nil
    end

    def lower_bb(b)
      i = @bb_first_insn[b]
      last = @bb_last_insn[b]
      while i <= last
        if @hir_deleted[i] == 0
          kind = @hir_kind[i]
          # jump / return の前に phi コピーを挿入する。
          if kind == HirOp::JUMP || kind == HirOp::JUMP_IF_FALSE || kind == HirOp::RETURN
            emit_phi_copies_for_bb(b)
          end
          lower_insn(i, b)
        end
        i += 1
      end
      # JIT-3c の GuardFixnum (BB 末尾範囲外) を、通常 insn の lower 後に処理。
      lower_guards_for_bb(b)
      nil
    end

    def lower_guards_for_bb(b)
      i = 0
      while i < @hir_kind.length
        if @hir_kind[i] == HirOp::GUARD_FIXNUM && @hir_bb[i] == b && @hir_deleted[i] == 0
          # GuardFixnum: x{op0} の bit 0 (Fixnum タグ) が 1 でなければ side exit。
          # TBZ x{op0}, #0, side_exit_label。side_exit のラベル解決は将来 JIT-4d。
          # 現段階では target_lir_id = -1 (未解決) としてダンプのみ。
          src = hir_to_reg(@hir_op0[i])
          emit_lir(LirOp::TBZ, src, 0, -1, b)
        end
        i += 1
      end
      nil
    end

    def emit_phi_copies_for_bb(from_bb)
      s0 = @bb_succ0[from_bb]
      if s0 >= 0
        emit_phi_copies_for_succ(from_bb, s0)
      end
      s1 = @bb_succ1[from_bb]
      if s1 >= 0
        emit_phi_copies_for_succ(from_bb, s1)
      end
      nil
    end

    def emit_phi_copies_for_succ(from_bb, to_bb)
      pred_count = @bb_preds_counts[to_bb]
      pred_start = @bb_preds_starts[to_bb]
      idx = -1
      pi = 0
      while pi < pred_count && idx < 0
        if @bb_preds_flat[pred_start + pi] == from_bb
          idx = pi
        end
        pi += 1
      end
      if idx < 0
        return nil
      end
      i = 0
      while i < @hir_kind.length
        if @hir_kind[i] == HirOp::PHI && @hir_bb[i] == to_bb && @hir_deleted[i] == 0
          args_start = @hir_op1[i]
          src_hir = @hir_phi_args[args_start + idx]
          if src_hir >= 0
            emit_lir(LirOp::MOV_REG, hir_to_reg(i), hir_to_reg(src_hir), 0, from_bb)
          end
        end
        i += 1
      end
      nil
    end

    def lower_insn(i, bb)
      kind = @hir_kind[i]
      if kind == HirOp::LOAD_CONST
        lower_load_const(i, bb)
      elsif kind == HirOp::LOAD_PARAM
        # arch 中立: 第 N 引数 (slot 0..7) を scratch reg にコピーする。
        # arm64 では X<slot>、x86_64 (SysV) では RDI/RSI/RDX/RCX/R8/R9 からの mov。
        emit_lir(LirOp::MOV_FROM_ARG, hir_to_reg(i), @hir_op0[i], 0, bb)
      elsif kind == HirOp::FIXNUM_ADD
        emit_lir(LirOp::ADD, hir_to_reg(i), hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), bb)
      elsif kind == HirOp::FIXNUM_SUB
        emit_lir(LirOp::SUB, hir_to_reg(i), hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), bb)
      elsif kind == HirOp::FIXNUM_MUL
        emit_lir(LirOp::MUL, hir_to_reg(i), hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), bb)
      elsif kind == HirOp::FIXNUM_DIV
        emit_lir(LirOp::SDIV, hir_to_reg(i), hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), bb)
      elsif kind == HirOp::FIXNUM_MOD
        # arm64 には MOD 命令がない。本格実装では `SDIV + MSUB` の 2 命令で表現するが、
        # 案 A の最小スコープでは SDIV のみ emit (= ダンプ上で「商」が見える) して、
        # 実機実行時の MSUB は将来の JIT-4d で対応する。
        emit_lir(LirOp::SDIV, hir_to_reg(i), hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), bb)
      elsif compare_kind?(kind) || fixnum_compare_kind?(kind)
        # 比較は CMP のみ emit。JumpIfFalse 側で B.cond を出す前提。
        emit_lir(LirOp::CMP, hir_to_reg(@hir_op0[i]), hir_to_reg(@hir_op1[i]), 0, bb)
      elsif kind == HirOp::JUMP
        emit_lir(LirOp::B, @bb_succ0[bb], 0, 0, bb)
      elsif kind == HirOp::JUMP_IF_FALSE
        # 直前の比較 HIR insn の kind から「偽分岐」相当の B.cond を選ぶ。
        # 例: FIXNUM_LT (a < b) が偽 (= a >= b) なら BB2 へ → B_GE。
        cond_hid = @hir_op0[i]
        cond_kind = @hir_kind[cond_hid]
        b_cond = lir_b_cond_for_false(cond_kind)
        emit_lir(b_cond, @bb_succ0[bb], 0, 0, bb)
      elsif kind == HirOp::CALL
        # 引数を arch 中立に並べる MOV_TO_ARG を emit してから BL。
        callee = @hir_op0[i]
        args_start = @hir_op1[i]
        arity = @hir_op2[i]
        ai = 0
        while ai < arity
          arg_hir = @hir_call_args[args_start + ai]
          emit_lir(LirOp::MOV_TO_ARG, ai, hir_to_reg(arg_hir), 0, bb)
          ai += 1
        end
        emit_lir(LirOp::BL, callee, 0, 0, bb)
        # 戻り値 (arm64: X0, x86_64: RAX) を hir_to_reg(i) にコピー。
        # MOV_FROM_ARG slot=0 が偶然「arm64 X0 / x86_64 RDI」に相当するため、ここは
        # 厳密には MOV_FROM_RET 相当の専用 op が望ましいが、現状 BL を含むメソッドは
        # 多 BB / cross-method の制約で install されないので未実装で問題なし。
        emit_lir(LirOp::MOV_REG, hir_to_reg(i), 0, 0, bb)
      elsif kind == HirOp::RETURN
        # 戻り値レジスタ (arm64: X0, x86_64: RAX) に値を置いて RET。
        emit_lir(LirOp::MOV_TO_RET, hir_to_reg(@hir_op0[i]), 0, 0, bb)
        emit_lir(LirOp::RET, 0, 0, 0, bb)
      end
      # PHI / PUTS / 観測なしの generic ADD 等は lower しない (= LIR には現れない)。
      nil
    end

    # 比較 HIR の偽分岐に対応する LirOp::B_* を返す (= JUMP_IF_FALSE で使う)。
    # LT 偽 = >= → B_GE、GT 偽 = <= → B_LE、LE 偽 = > → B_GT、GE 偽 = < → B_LT、
    # EQ 偽 = != → B_NE。それ以外 (bool 値直接) は B_EQ で fallback。
    def lir_b_cond_for_false(cond_kind)
      result = LirOp::B_EQ
      if cond_kind == HirOp::LT || cond_kind == HirOp::FIXNUM_LT
        result = LirOp::B_GE
      elsif cond_kind == HirOp::GT || cond_kind == HirOp::FIXNUM_GT
        result = LirOp::B_LE
      elsif cond_kind == HirOp::LE || cond_kind == HirOp::FIXNUM_LE
        result = LirOp::B_GT
      elsif cond_kind == HirOp::GE || cond_kind == HirOp::FIXNUM_GE
        result = LirOp::B_LT
      elsif cond_kind == HirOp::EQ || cond_kind == HirOp::FIXNUM_EQ
        result = LirOp::B_NE
      end
      result
    end

    def lower_load_const(i, bb)
      tag = @hir_op0[i]
      if tag == HirConstTag::INT
        # box 形式 (n << 1 | 1) で MOVZ。MOVZ は 16bit zero-extend なので、
        # 負数の boxed 値や 16bit を超える整数は上位 bit が落ちて誤った値になる。
        # 完全対応には MOVN または MOVZ + MOVK チェーンが必要だが、案 A (実機実行
        # なし、ダンプのみ) では下位 16bit のみ表示する素朴版。
        v = (@hir_op1[i] << 1) | 1
        emit_lir(LirOp::MOV_IMM, hir_to_reg(i), v & 0xFFFF, 0, bb)
      elsif tag == HirConstTag::TRUE
        emit_lir(LirOp::MOV_IMM, hir_to_reg(i), ObjectVal::TRUE_VAL, 0, bb)
      elsif tag == HirConstTag::FALSE
        emit_lir(LirOp::MOV_IMM, hir_to_reg(i), ObjectVal::FALSE_VAL, 0, bb)
      elsif tag == HirConstTag::NIL
        emit_lir(LirOp::MOV_IMM, hir_to_reg(i), ObjectVal::NIL_VAL, 0, bb)
      end
      nil
    end

    def pass_encode_arm64
      i = 0
      while i < @lir_kind.length
        @lir_machine_code.push(encode_arm64_insn(i))
        i += 1
      end
      nil
    end

    # アーキ別エンコーダの dispatcher。defined?(JIT) かつ JIT::ARCH_ARM64 == false の
    # 環境 (= AOT バイナリ + x86_64 ホスト) で x86_64 を選ぶ。それ以外 (CRuby、AOT
    # arm64、@dump_hir 用) は従来通り arm64 を生成し @lir_machine_code を埋める。
    def pass_encode_native
      if defined?(JIT) && JIT::ARCH_ARM64 == false
        pass_encode_x86_64
      else
        pass_encode_arm64
      end
      nil
    end

    # JIT-4c x86_64 (System V AMD64) エンコーダ。arm64 と違って可変長命令なので
    # @jit_bytes IntArray に 1 byte ずつ push する。pass_encode_arm64 と違い 2 段階
    # (encode + label fixup) で構成する。複数 BB / call を持つメソッドは encoder 側
    # の未解決 task と同じく install_jit_for_method 側で弾く。
    def pass_encode_x86_64
      @lir_byte_offset = []
      i = 0
      while i < @lir_kind.length
        @lir_byte_offset.push(@jit_bytes.length)
        emit_x86_64_insn(i)
        i += 1
      end
      nil
    end

    # JIT install できる物理的条件が揃っているか (モジュール存在のみ確認)。
    # CRuby は JIT 未定義のため defined?(JIT) で false 側に倒れる。AOT 上で arm64 /
    # x86_64 のいずれかで動作可能。アーキ別の対応可否は install_jit_for_method 内で判定。
    def jit_install_viable?
      if defined?(JIT)
        return true
      end
      false
    end

    # JIT-4c: encode 済みの機械語を実機実行可能な buffer に書き込む。arm64 は
    # @lir_machine_code (32bit word x N) を write_words で、x86_64 は @jit_bytes
    # (1 byte x N) を write_bytes で転送する。arity > 8 / 空 LIR / SysV で arity > 6
    # は install をスキップ (@jit_fn_addrs[m_idx] = -1 でマーク、以後再試行しない)。
    # BL や分岐の target 解決は encoder 側の未解決 task で、複数 BB を持つメソッドは
    # crash する可能性が高い ── ここでは「install できる入力なら install する」のみ。
    def install_jit_for_method(m_idx)
      if @method_arities[m_idx] > 8
        @jit_fn_addrs[m_idx] = -1
        return nil
      end
      bytes = 0
      if JIT::ARCH_ARM64
        bytes = @lir_machine_code.length * 4
      else
        # x86_64 SysV は arg register が 6 個まで。7+ はスタック渡しが必要で未対応。
        if @method_arities[m_idx] > 6
          @jit_fn_addrs[m_idx] = -1
          return nil
        end
        bytes = @jit_bytes.length
      end
      if bytes == 0
        @jit_fn_addrs[m_idx] = -1
        return nil
      end
      page = JIT.page_size
      size = ((bytes + page - 1) / page) * page

      addr = JIT.alloc(size, JIT::PROT_READ | JIT::PROT_WRITE | JIT::PROT_EXEC)
      if addr == 0
        @jit_fn_addrs[m_idx] = -1
        return nil
      end

      if JIT::DARWIN_ARM64
        # macOS arm64: MAP_JIT ページは pthread_jit_write_protect_np(0) で書き込み解禁
        JIT.jit_write_protect(false)
      end
      if JIT::ARCH_ARM64
        JIT.write_words(addr, @lir_machine_code)
      else
        JIT.write_bytes(addr, @jit_bytes)
      end
      if JIT::DARWIN_ARM64
        JIT.jit_write_protect(true)
      end
      # arm64 (Linux/macOS) は icache flush が必須。x86_64 は cache coherent。
      if JIT::ARCH_ARM64
        JIT.clear_icache(addr, bytes)
      end

      @jit_fn_addrs[m_idx] = addr
      @jit_fn_sizes[m_idx] = size
      nil
    end

    # JIT-4c: install 済み JIT エントリにディスパッチ。スタック末尾 argc 個を引数に
    # 取り、callN で関数ポインタへ jmp。返り値をスタックに push して 1 を返す。
    # 戻り値 0 = 「JIT 経路に乗せず通常 frame push を続行」(=現状常に 1 を返すので
    # 将来 deopt が要るときに使う想定)。
    def dispatch_jit_call(m_idx, argc, fn_addr)
      a0 = 0; a1 = 0; a2 = 0; a3 = 0; a4 = 0; a5 = 0; a6 = 0; a7 = 0
      # 引数は最後に push したものが最後の引数。逆順 pop でレジスタ順に並べる。
      if argc == 0
        # no args
      elsif argc == 1
        a0 = @stack.pop
      elsif argc == 2
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 3
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 4
        a3 = @stack.pop
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 5
        a4 = @stack.pop
        a3 = @stack.pop
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 6
        a5 = @stack.pop
        a4 = @stack.pop
        a3 = @stack.pop
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 7
        a6 = @stack.pop
        a5 = @stack.pop
        a4 = @stack.pop
        a3 = @stack.pop
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      elsif argc == 8
        a7 = @stack.pop
        a6 = @stack.pop
        a5 = @stack.pop
        a4 = @stack.pop
        a3 = @stack.pop
        a2 = @stack.pop
        a1 = @stack.pop
        a0 = @stack.pop
      else
        # 9 引数以上は install 時に弾いているはず。防御として install 失敗扱いにして
        # 通常 frame push に流す。
        @jit_fn_addrs[m_idx] = -1
        return 0
      end

      ret = 0
      if argc == 0
        ret = JIT.call0(fn_addr)
      elsif argc == 1
        ret = JIT.call1(fn_addr, a0)
      elsif argc == 2
        ret = JIT.call2(fn_addr, a0, a1)
      elsif argc == 3
        ret = JIT.call3(fn_addr, a0, a1, a2)
      elsif argc == 4
        ret = JIT.call4(fn_addr, a0, a1, a2, a3)
      elsif argc == 5
        ret = JIT.call5(fn_addr, a0, a1, a2, a3, a4)
      elsif argc == 6
        ret = JIT.call6(fn_addr, a0, a1, a2, a3, a4, a5)
      elsif argc == 7
        ret = JIT.call7(fn_addr, a0, a1, a2, a3, a4, a5, a6)
      elsif argc == 8
        ret = JIT.call8(fn_addr, a0, a1, a2, a3, a4, a5, a6, a7)
      end
      @stack.push(ret)
      1
    end

    def encode_arm64_insn(lir_id)
      kind = @lir_kind[lir_id]
      # 未知 kind のフォールバック値。0 は arm64 で UDF #0 (= 不正命令) なので、
      # ダンプで「0xdead0000」が出れば「LirOp 追加忘れ」と気付ける目印。
      result = 0xDEAD0000
      if kind == LirOp::MOV_IMM
        result = encode_movz(@lir_op0[lir_id], @lir_op1[lir_id])
      elsif kind == LirOp::MOV_REG
        result = encode_orr_xzr(@lir_op0[lir_id], @lir_op1[lir_id])
      elsif kind == LirOp::MOV_FROM_ARG
        # arm64: arg slot N は X<N>。MOV X<dst>, X<slot> と同じ。
        result = encode_orr_xzr(@lir_op0[lir_id], @lir_op1[lir_id])
      elsif kind == LirOp::MOV_TO_ARG
        # arm64: 同じく MOV X<slot>, X<src>。
        result = encode_orr_xzr(@lir_op0[lir_id], @lir_op1[lir_id])
      elsif kind == LirOp::MOV_TO_RET
        # arm64: 戻り値レジスタは X0。MOV X0, X<src>。op0 = src reg。
        result = encode_orr_xzr(0, @lir_op0[lir_id])
      elsif kind == LirOp::ADD
        result = encode_add_reg(@lir_op0[lir_id], @lir_op1[lir_id], @lir_op2[lir_id])
      elsif kind == LirOp::SUB
        result = encode_sub_reg(@lir_op0[lir_id], @lir_op1[lir_id], @lir_op2[lir_id])
      elsif kind == LirOp::MUL
        result = encode_mul_reg(@lir_op0[lir_id], @lir_op1[lir_id], @lir_op2[lir_id])
      elsif kind == LirOp::SDIV
        result = encode_sdiv_reg(@lir_op0[lir_id], @lir_op1[lir_id], @lir_op2[lir_id])
      elsif kind == LirOp::CMP
        result = encode_cmp_reg(@lir_op0[lir_id], @lir_op1[lir_id])
      elsif kind == LirOp::B
        # target は BB id。実機の offset 解決は JIT-4d で。今はラベル番号を生埋め。
        result = encode_b(@lir_op0[lir_id])
      elsif kind == LirOp::B_NE
        result = encode_b_cond(Arm64Cond::NE, @lir_op0[lir_id])
      elsif kind == LirOp::B_EQ
        result = encode_b_cond(Arm64Cond::EQ, @lir_op0[lir_id])
      elsif kind == LirOp::B_LT
        result = encode_b_cond(Arm64Cond::LT, @lir_op0[lir_id])
      elsif kind == LirOp::B_GT
        result = encode_b_cond(Arm64Cond::GT, @lir_op0[lir_id])
      elsif kind == LirOp::B_LE
        result = encode_b_cond(Arm64Cond::LE, @lir_op0[lir_id])
      elsif kind == LirOp::B_GE
        result = encode_b_cond(Arm64Cond::GE, @lir_op0[lir_id])
      elsif kind == LirOp::BL
        result = encode_bl(@lir_op0[lir_id])
      elsif kind == LirOp::RET
        result = encode_ret
      elsif kind == LirOp::TBZ
        # TBZ Rt, #imm6, label (= bit が 0 なら branch)。
        result = encode_tbz(@lir_op0[lir_id], @lir_op1[lir_id], @lir_op2[lir_id])
      end
      result
    end

    # MOVZ Xd, #imm16 : 1101 0010 100 imm16 Rd
    def encode_movz(rd, imm16)
      0xD2800000 | ((imm16 & 0xFFFF) << 5) | (rd & 0x1F)
    end

    # MOV (register) = ORR Xd, XZR, Xm : 1010 1010 000 Rm 000000 11111 Rd
    def encode_orr_xzr(rd, rm)
      0xAA0003E0 | ((rm & 0x1F) << 16) | (rd & 0x1F)
    end

    # ADD Xd, Xn, Xm : 1000 1011 000 Rm 000000 Rn Rd
    def encode_add_reg(rd, rn, rm)
      0x8B000000 | ((rm & 0x1F) << 16) | ((rn & 0x1F) << 5) | (rd & 0x1F)
    end

    # SUB Xd, Xn, Xm : 1100 1011 000 Rm 000000 Rn Rd
    def encode_sub_reg(rd, rn, rm)
      0xCB000000 | ((rm & 0x1F) << 16) | ((rn & 0x1F) << 5) | (rd & 0x1F)
    end

    # MUL Xd, Xn, Xm = MADD Xd, Xn, Xm, XZR : 1001 1011 000 Rm 0 11111 Rn Rd
    def encode_mul_reg(rd, rn, rm)
      0x9B007C00 | ((rm & 0x1F) << 16) | ((rn & 0x1F) << 5) | (rd & 0x1F)
    end

    # SDIV Xd, Xn, Xm : 1001 1010 110 Rm 000011 Rn Rd
    def encode_sdiv_reg(rd, rn, rm)
      0x9AC00C00 | ((rm & 0x1F) << 16) | ((rn & 0x1F) << 5) | (rd & 0x1F)
    end

    # CMP Xn, Xm = SUBS XZR, Xn, Xm : 1110 1011 000 Rm 000000 Rn 11111
    def encode_cmp_reg(rn, rm)
      0xEB00001F | ((rm & 0x1F) << 16) | ((rn & 0x1F) << 5)
    end

    # B label : 0001 0100 imm26 (offset26 は 4byte 単位、現段階では label 番号生埋め)
    def encode_b(target)
      0x14000000 | (target & 0x3FFFFFF)
    end

    # B.cond label : 0101 0100 imm19 0 cond
    def encode_b_cond(cond, target)
      0x54000000 | ((target & 0x7FFFF) << 5) | (cond & 0xF)
    end

    # BL imm26 : 1001 0100 imm26
    def encode_bl(target)
      0x94000000 | (target & 0x3FFFFFF)
    end

    # RET Xn (default Xn=30) : 1101 0110 0101 1111 0000 00 Rn 00000
    def encode_ret
      0xD65F0000 | (30 << 5)
    end

    # TBZ Rt, #b40, label : b5(31) 011011 op(24=0=TBZ) b40(23:19) imm14(18:5) Rt(4:0)。
    # b5 はビット番号の bit5 (0..31 のテストなら 0、32..63 なら 1)。setsunaruby は
    # Fixnum タグ (bit 0) のチェックにしか使わないので b5=0 → ベース 0x36000000。
    # target=-1 (未解決) のときは imm14 が 0x3FFF に汚染されないよう 0 にクランプ。
    def encode_tbz(rt, bit, target)
      safe_target = target
      if safe_target < 0
        safe_target = 0
      end
      0x36000000 | ((bit & 0x1F) << 19) | ((safe_target & 0x3FFF) << 5) | (rt & 0x1F)
    end

    # ============================================================
    # JIT-4c x86_64 (System V AMD64) エンコーダ
    # ============================================================
    # arm64 と違って可変長命令 (1〜15 byte)。@jit_bytes IntArray に 1 byte/slot で
    # 蓄積する。LIR は arch 中立 (= 同じ vreg / 同じ opcode 種別) だが、エンコード時に
    # x86_64 reg num にマップし、計算用は 2-operand 制約 (dst = lhs を強制) で出す。
    # SysV AMD64 calling convention: 引数 RDI, RSI, RDX, RCX, R8, R9; 戻り値 RAX。

    # x86_64 reg 番号 (ModRM 用)。lower 3 bit が ModRM 内、上位 1 bit が REX.B/R 用。
    X64_RAX = 0
    X64_RDX = 2
    X64_RBX = 3
    X64_RSI = 6
    X64_RDI = 7
    X64_R8  = 8
    X64_R9  = 9

    # SysV AMD64 の引数 slot N (0..5) を x86_64 reg 番号に変換。arity > 6 は
    # install_jit_for_method 側で弾く。
    def x86_64_arg_reg(slot)
      result = X64_RDI
      if slot == 0
        result = X64_RDI
      elsif slot == 1
        result = X64_RSI
      elsif slot == 2
        result = X64_RDX
      elsif slot == 3
        result = 1            # RCX
      elsif slot == 4
        result = X64_R8
      elsif slot == 5
        result = X64_R9
      end
      result
    end

    # LIR vreg 番号 (= hir_to_reg の戻り値、典型 9..28) を x86_64 物理 reg 番号
    # (8..15 = r8..r15) に変換。0..7 は MOV_REG の例外用に そのままの 0..7 = rax..rdi。
    def x86_64_phys_reg(vreg)
      result = X64_RAX
      if vreg <= 7
        result = vreg
      elsif vreg == 8
        result = X64_R8
      else
        result = ((vreg - 9) % 8) + 8
      end
      result
    end

    # REX prefix。w=1 (64bit operand)、r/x/b は ModRM/SIB 拡張用。
    def x86_64_rex(w, r, x, b)
      0x40 | (w << 3) | (r << 2) | (x << 1) | b
    end

    # 32bit 整数を little-endian で @jit_bytes に 4 byte push。
    def x86_64_push_u32_le(v)
      @jit_bytes.push(v & 0xFF)
      @jit_bytes.push((v >> 8) & 0xFF)
      @jit_bytes.push((v >> 16) & 0xFF)
      @jit_bytes.push((v >> 24) & 0xFF)
      nil
    end

    # reg-to-reg 系 (mov/add/sub/cmp 等) の共通 emit。dst は ModRM.r/m に、src は
    # ModRM.reg に入り、REX.B / REX.R が必要に応じて立つ。opcode は呼び側で指定。
    def x86_64_emit_rrm(opcode, dst, src)
      rex_r = 0
      if src >= 8
        rex_r = 1
      end
      rex_b = 0
      if dst >= 8
        rex_b = 1
      end
      @jit_bytes.push(x86_64_rex(1, rex_r, 0, rex_b))
      @jit_bytes.push(opcode)
      @jit_bytes.push(0xC0 | ((src & 7) << 3) | (dst & 7))
      nil
    end

    # 0x81 系 ALU imm32 (add/sub/and/or/xor 等)。reg_field は /N の N (0=add, 5=sub)。
    def x86_64_emit_alu_imm32(reg_field, dst, imm32)
      rex_b = 0
      if dst >= 8
        rex_b = 1
      end
      @jit_bytes.push(x86_64_rex(1, 0, 0, rex_b))
      @jit_bytes.push(0x81)
      @jit_bytes.push(0xC0 | ((reg_field & 7) << 3) | (dst & 7))
      x86_64_push_u32_le(imm32)
      nil
    end

    def x86_64_emit_mov_reg(dst, src)
      x86_64_emit_rrm(0x89, dst, src)
    end

    def x86_64_emit_add_reg(dst, src)
      x86_64_emit_rrm(0x01, dst, src)
    end

    def x86_64_emit_sub_reg(dst, src)
      x86_64_emit_rrm(0x29, dst, src)
    end

    # cmp r/m64, r64: r/m が lhs、reg が rhs。
    def x86_64_emit_cmp_reg(lhs, rhs)
      x86_64_emit_rrm(0x39, lhs, rhs)
    end

    # mov r/m64, imm32 (opcode 0xc7 /0)。imm32 は符号拡張で 64bit に。
    # boxed Fixnum は MOVZ #imm16 想定 (= 16bit 即値) なので 32bit に十分収まる。
    def x86_64_emit_mov_imm32(dst, imm32)
      rex_b = 0
      if dst >= 8
        rex_b = 1
      end
      @jit_bytes.push(x86_64_rex(1, 0, 0, rex_b))
      @jit_bytes.push(0xC7)
      @jit_bytes.push(0xC0 | (dst & 7))
      x86_64_push_u32_le(imm32)
      nil
    end

    # 1 LIR insn を x86_64 バイト列にエンコードして @jit_bytes に push。
    # 命令長は固定。BL や TBZ など x86_64 未対応の op に当たった場合は no-op を emit
    # しておき、install 側で多 BB / call を検出して弾く。
    def emit_x86_64_insn(lir_id)
      kind = @lir_kind[lir_id]
      if kind == LirOp::RET
        @jit_bytes.push(0xC3)
      elsif kind == LirOp::MOV_IMM
        dst = x86_64_phys_reg(@lir_op0[lir_id])
        x86_64_emit_mov_imm32(dst, @lir_op1[lir_id])
      elsif kind == LirOp::MOV_REG
        x86_64_emit_mov_reg(x86_64_phys_reg(@lir_op0[lir_id]),
                            x86_64_phys_reg(@lir_op1[lir_id]))
      elsif kind == LirOp::MOV_FROM_ARG
        x86_64_emit_mov_reg(x86_64_phys_reg(@lir_op0[lir_id]),
                            x86_64_arg_reg(@lir_op1[lir_id]))
      elsif kind == LirOp::MOV_TO_ARG
        x86_64_emit_mov_reg(x86_64_arg_reg(@lir_op0[lir_id]),
                            x86_64_phys_reg(@lir_op1[lir_id]))
      elsif kind == LirOp::MOV_TO_RET
        x86_64_emit_mov_reg(X64_RAX, x86_64_phys_reg(@lir_op0[lir_id]))
      elsif kind == LirOp::ADD
        # 2-operand: dst = lhs; dst += rhs
        dst = x86_64_phys_reg(@lir_op0[lir_id])
        lhs = x86_64_phys_reg(@lir_op1[lir_id])
        rhs = x86_64_phys_reg(@lir_op2[lir_id])
        if dst != lhs
          x86_64_emit_mov_reg(dst, lhs)
        end
        x86_64_emit_add_reg(dst, rhs)
      elsif kind == LirOp::SUB
        dst = x86_64_phys_reg(@lir_op0[lir_id])
        lhs = x86_64_phys_reg(@lir_op1[lir_id])
        rhs = x86_64_phys_reg(@lir_op2[lir_id])
        if dst != lhs
          x86_64_emit_mov_reg(dst, lhs)
        end
        x86_64_emit_sub_reg(dst, rhs)
      elsif kind == LirOp::CMP
        x86_64_emit_cmp_reg(x86_64_phys_reg(@lir_op0[lir_id]),
                            x86_64_phys_reg(@lir_op1[lir_id]))
      elsif kind == LirOp::B || kind == LirOp::B_EQ || kind == LirOp::B_NE || kind == LirOp::B_LT || kind == LirOp::B_GT || kind == LirOp::B_LE || kind == LirOp::B_GE
        # 多 BB は install 側で弾く。プレースホルダとして jmp rel32 (5 byte) を出す。
        @jit_bytes.push(0xE9)
        x86_64_push_u32_le(0)
      elsif kind == LirOp::BL
        # cross-method/再帰は install 側で弾く。プレースホルダ call rel32 (5 byte)。
        @jit_bytes.push(0xE8)
        x86_64_push_u32_le(0)
      elsif kind == LirOp::TBZ
        # GUARD_FIXNUM の TBZ。x86_64 では test+jz 相当だが現状の install 経路では
        # 多 BB と一緒に弾かれる。6 byte の NOP 列を emit してサイズを揃える。
        bi = 0
        while bi < 6
          @jit_bytes.push(0x90)
          bi += 1
        end
      end
      nil
    end

    def dump_lir(m_idx)
      STDERR.puts "ZJIT LIR for method idx=#{m_idx}:"
      # x86_64 では @lir_machine_code が空で @jit_bytes に byte 列が並ぶ。命令長が
      # 可変なので 32bit hex の 1:1 対応が無いため、x86_64 では asm のみ表示する。
      use_arm64_hex = 1
      if @lir_machine_code.length == 0
        use_arm64_hex = 0
      end
      i = 0
      cur_bb = -1
      while i < @lir_kind.length
        bb = @lir_bb[i]
        if bb != cur_bb
          STDERR.puts "  BB#{bb}:"
          cur_bb = bb
        end
        asm = format_lir_asm(i)
        if use_arm64_hex == 1
          hex = format_hex32(@lir_machine_code[i])
          STDERR.puts "    #{asm}    ; #{hex}"
        else
          STDERR.puts "    #{asm}"
        end
        i += 1
      end
      nil
    end

    def format_hex32(v)
      result = "0x"
      i = 7
      while i >= 0
        nibble = (v >> (i * 4)) & 0xF
        if nibble < 10
          result = result + nibble.to_s
        elsif nibble == 10
          result = result + "a"
        elsif nibble == 11
          result = result + "b"
        elsif nibble == 12
          result = result + "c"
        elsif nibble == 13
          result = result + "d"
        elsif nibble == 14
          result = result + "e"
        elsif nibble == 15
          result = result + "f"
        end
        i -= 1
      end
      result
    end

    def format_lir_asm(i)
      kind = @lir_kind[i]
      op0  = @lir_op0[i]
      op1  = @lir_op1[i]
      op2  = @lir_op2[i]
      result = "?"
      if kind == LirOp::MOV_IMM
        result = "mov x" + op0.to_s + ", #" + op1.to_s
      elsif kind == LirOp::MOV_REG
        result = "mov x" + op0.to_s + ", x" + op1.to_s
      elsif kind == LirOp::MOV_FROM_ARG
        result = "mov x" + op0.to_s + ", arg" + op1.to_s
      elsif kind == LirOp::MOV_TO_ARG
        result = "mov arg" + op0.to_s + ", x" + op1.to_s
      elsif kind == LirOp::MOV_TO_RET
        result = "mov ret, x" + op0.to_s
      elsif kind == LirOp::ADD
        result = "add x" + op0.to_s + ", x" + op1.to_s + ", x" + op2.to_s
      elsif kind == LirOp::SUB
        result = "sub x" + op0.to_s + ", x" + op1.to_s + ", x" + op2.to_s
      elsif kind == LirOp::MUL
        result = "mul x" + op0.to_s + ", x" + op1.to_s + ", x" + op2.to_s
      elsif kind == LirOp::SDIV
        result = "sdiv x" + op0.to_s + ", x" + op1.to_s + ", x" + op2.to_s
      elsif kind == LirOp::CMP
        result = "cmp x" + op0.to_s + ", x" + op1.to_s
      elsif kind == LirOp::B
        result = "b BB" + op0.to_s
      elsif kind == LirOp::B_EQ
        result = "b.eq BB" + op0.to_s
      elsif kind == LirOp::B_NE
        result = "b.ne BB" + op0.to_s
      elsif kind == LirOp::B_LT
        result = "b.lt BB" + op0.to_s
      elsif kind == LirOp::B_GT
        result = "b.gt BB" + op0.to_s
      elsif kind == LirOp::B_LE
        result = "b.le BB" + op0.to_s
      elsif kind == LirOp::B_GE
        result = "b.ge BB" + op0.to_s
      elsif kind == LirOp::BL
        result = "bl m" + op0.to_s
      elsif kind == LirOp::RET
        result = "ret"
      elsif kind == LirOp::TBZ
        result = "tbz x" + op0.to_s + ", #" + op1.to_s + ", side_exit"
      end
      result
    end
  end
end
