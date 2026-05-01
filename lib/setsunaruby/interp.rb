require_relative 'token'
require_relative 'ast'
require_relative 'opcodes'
require_relative 'hir_opcodes'
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
    SP    = 32
    HASH  = 35
    LP    = 40
    RP    = 41
    STAR_BYTE  = 42
    PLUS_BYTE  = 43
    COMMA_BYTE = 44
    MINUS_BYTE = 45
    SLASH_BYTE = 47
    PCT   = 37
    EQ    = 61
    LT_BYTE = 60
    GT_BYTE = 62
    UND   = 95
    D0    = 48
    D9    = 57
    A_LC  = 97
    Z_LC  = 122
    A_UC  = 65
    Z_UC  = 90

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
      # JIT-2: HIR (lite SSA) を SoA で保持。build_and_dump_hir が再構築する。
      @hir_kind      = []   # IntArray (HirOp 定数)
      @hir_op0       = []   # IntArray (kind ごとの 1 番目のオペランド)
      @hir_op1       = []   # IntArray
      @hir_op2       = []   # IntArray
      @hir_call_args = []   # IntArray (CALL の引数 hir_id を flat に並べる)
      @hir_deleted   = []   # IntArray (JIT-3: 0=alive, 1=dead。eliminate_dead_code が mark)
      # spinel AOT で ENV が解釈されない場合は常に false 相当 (HIR ダンプは CRuby のみ)。
      @dump_hir      = ENV["SETSUNARUBY_DUMP_HIR"] == "1"
      # VM のコールフレームスタック (並列 IntArray)。
      # locals の縮小は @cur_base で行うので length 自体は記録しない。
      @cfp_pcs   = []   # IntArray (戻り PC)
      @cfp_bases = []   # IntArray (戻り後の @cur_base)
      @cur_base  = 0    # 現在実行中の locals base
    end

    def run_file(path)
      run_string(File.read(path))
    end

    def run_string(src)
      @src          = src
      @bytes        = src.bytes
      @lex_pos      = 0
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
      @hir_kind      = []
      @hir_op0       = []
      @hir_op1       = []
      @hir_op2       = []
      @hir_call_args = []
      @hir_deleted   = []
      @dump_hir      = ENV["SETSUNARUBY_DUMP_HIR"] == "1"
      @cfp_pcs   = []
      @cfp_bases = []
      @cur_base  = 0

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

    def read_ident_or_keyword
      start = @lex_pos
      while @lex_pos < @bytes.length && ident_cont?(@bytes[@lex_pos])
        @lex_pos += 1
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
      elsif b == EQ
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::EQ_EQ, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::EQ, 0, "", @line)
        end
      elsif b == LT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::LE, 0, "", @line)
        else
          @lex_pos += 1
          Token.new(TokenKind::LT, 0, "", @line)
        end
      elsif b == GT_BYTE
        if @lex_pos + 1 < @bytes.length && @bytes[@lex_pos + 1] == EQ
          @lex_pos += 2
          Token.new(TokenKind::GE, 0, "", @line)
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
      elsif k == TokenKind::KW_DEF
        return parse_def
      elsif k == TokenKind::KW_RETURN
        return parse_return
      else
        return parse_expression
      end
    end

    # 既に primary を 1 つ読み終えた状態から、続く演算子を取り込んで式を完成させる。
    def parse_expression_from(left, _line)
      left = parse_multiplicative_from(left)
      left = parse_additive_continue(left)
      left = parse_comparison_continue(left)
      left
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

    def parse_comparison_continue(left)
      tk = @cur_token.kind
      op = :nop
      if tk == TokenKind::EQ_EQ
        op = :eq
      elsif tk == TokenKind::LT
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
        right = parse_additive
        tk2 = @cur_token.kind
        if tk2 == TokenKind::EQ_EQ || tk2 == TokenKind::LT || tk2 == TokenKind::GT ||
           tk2 == TokenKind::LE   || tk2 == TokenKind::GE
          raise "Parse error: line #{@cur_token.line}: 比較演算子の連鎖は許可されていません"
        end
        ASTNode.new(:bin_op, 0, false, op, left, right, nil)
      else
        left
      end
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

    # 複数文を右結合の :seq チェーンに組み立てる。
    # 終端: end / else / elsif / EOF。
    # 文の区切りは NEWLINE またはブロック終端キーワード (else/elsif/end) を許す。
    # これにより `if true then 10 else 20 end` のような単一行も書ける。
    def parse_block
      skip_newlines
      if at_block_end?
        return ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
      end
      first = parse_statement
      consume_block_terminator
      skip_newlines
      if at_block_end?
        return first
      end
      rest = parse_block
      ASTNode.new(:seq, 0, false, :nop, first, nil, rest)
    end

    def consume_block_terminator
      k = @cur_token.kind
      if k == TokenKind::NEWLINE || k == TokenKind::EOF ||
         k == TokenKind::KW_END  || k == TokenKind::KW_ELSE ||
         k == TokenKind::KW_ELSIF
        # OK (NEWLINE は呼び出し元の skip_newlines で消費)
      else
        raise "Parse error: line #{@cur_token.line}: 文の終端 (改行/end/else/elsif) が必要です"
      end
      nil
    end

    def at_block_end?
      k = @cur_token.kind
      k == TokenKind::KW_END || k == TokenKind::KW_ELSE ||
        k == TokenKind::KW_ELSIF || k == TokenKind::EOF
    end

    # expression := IDENT '=' expression       (代入は右結合)
    #             | comparison
    # 代入は最も低い優先順位で右結合。`x = y = 1` は `x = (y = 1)` となる。
    def parse_expression
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
          # メソッド呼び出し: ident '(' args ')'
          @cur_token = next_token
          args = parse_arg_list
          expect(TokenKind::RPAREN)
          left_node = ASTNode.new(:method_call, packed, false, :nop, args, nil, nil)
          return parse_expression_from(left_node, line)
        else
          left_node = ASTNode.new(:var_ref, packed, false, :nop, nil, nil, nil)
          return parse_expression_from(left_node, line)
        end
      end
      parse_comparison
    end

    def parse_comparison
      left = parse_additive
      parse_comparison_continue(left)
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
      if @cur_token.kind == TokenKind::MINUS
        @cur_token = next_token
        ASTNode.new(:unary_minus, 0, false, :nop, nil, nil, parse_unary)
      else
        parse_primary
      end
    end

    def parse_primary
      k = @cur_token.kind
      if k == TokenKind::INT
        v = @cur_token.int_value
        @cur_token = next_token
        ASTNode.new(:int_lit, v, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_TRUE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, true, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_FALSE
        @cur_token = next_token
        ASTNode.new(:bool_lit, 0, false, :nop, nil, nil, nil)
      elsif k == TokenKind::KW_NIL
        @cur_token = next_token
        ASTNode.new(:nil_lit, 0, false, :nop, nil, nil, nil)
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
      elsif k == TokenKind::KW_IF
        parse_if
      elsif k == TokenKind::KW_WHILE
        parse_while
      else
        raise "Parse error: line #{@cur_token.line}: 式が必要です"
      end
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
      elsif k == :return_stmt
        compile_return(node)
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
      elsif k == :bool_lit
        if node.node_bool_value
          @bytecode.push(Op::PUSH_TRUE)
        else
          @bytecode.push(Op::PUSH_FALSE)
        end
      elsif k == :nil_lit
        @bytecode.push(Op::PUSH_NIL)
      elsif k == :bin_op
        compile_expr(node.node_left)
        compile_expr(node.node_right)
        @bytecode.push(binop_to_opcode(node.node_op))
      elsif k == :unary_minus
        @bytecode.push(Op::PUSH_INT)
        encode_signed(0)
        compile_expr(node.node_operand)
        @bytecode.push(Op::SUB)
      elsif k == :var_ref
        pkt = node.node_int_value
        idx = find_local(pkt)
        if idx >= 0
          @bytecode.push(Op::LOAD_LOCAL)
          encode_signed(idx)
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
      else
        raise "Compiler bug: unknown expression kind #{k}"
      end
      nil
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

      patch_jump(skip_jump_pos, @bytecode.length)
      # def 文自体の値は nil (compile_stmt の不変条件「1 値残す」を維持)。
      @bytecode.push(Op::PUSH_NIL)
      nil
    end

    def compile_method_call(node)
      name_packed = node.node_int_value
      m_idx = find_method(name_packed)
      if m_idx < 0
        raise "Compile error: line #{@cur_token.line}: 未定義のメソッド呼び出しです"
      end
      expected = @method_arities[m_idx]
      argc = count_arg_chain(node.node_left)
      if expected != argc
        raise "Compile error: line #{@cur_token.line}: 引数の個数が一致しません (期待 #{expected}, 実際 #{argc})"
      end
      # 引数を左から右の順に評価して push (stack top が最後の引数)。
      cur = node.node_left
      while cur != nil
        compile_expr(cur.node_left)
        cur = cur.node_operand
      end
      @bytecode.push(Op::CALL)
      encode_signed(m_idx)
      nil
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

    def find_method(name_packed)
      find_in_table(@method_name_starts, @method_name_lens, 0, name_packed)
    end

    # 並列 IntArray (starts, lens) で構成された name table を線形探索する。
    # start_idx 以降だけ走査するので、スコープ相対探索 (find_local) も同じ
    # ヘルパーで賄える。見つかれば絶対 idx を、見つからなければ -1 を返す。
    def find_in_table(starts, lens, start_idx, packed)
      pkg_start = packed >> 16
      pkg_len   = packed & 0xffff
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
      i = find_method(name_packed)
      if i < 0
        @method_name_starts.push(name_packed >> 16)
        @method_name_lens.push(name_packed & 0xffff)
        @method_pcs.push(method_pc)
        @method_arities.push(arity)
        @method_local_counts.push(0)
        @method_body_ends.push(-1)
        @jit_call_counts.push(0)
        i = @method_name_starts.length - 1
      else
        @method_pcs[i] = method_pc
        @method_arities[i] = arity
        @method_local_counts[i] = 0
        @method_body_ends[i] = -1
        @jit_call_counts[i] = 0
      end
      i
    end

    def compile_while(node)
      loop_start = @bytecode.length
      compile_expr(node.node_left)
      jexit_pos = emit_jump(Op::JUMP_IF_FALSE)
      compile_block(node.node_right)
      @bytecode.push(Op::POP)            # body の値を破棄
      back_jump_pos = emit_jump(Op::JUMP)
      patch_jump(back_jump_pos, loop_start)
      patch_jump(jexit_pos, @bytecode.length)
      @bytecode.push(Op::PUSH_NIL)        # while 全体の値は nil
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
      else
        raise "Compiler bug: unknown binop #{op}"
      end
      result
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
        elsif op == Op::PUTS
          v = @stack.pop
          puts to_puts_string(v)
          @stack.push(ObjectVal::NIL_VAL)   # Stage 1: puts は nil を返す
        elsif op == Op::CALL
          exec_call
        elsif op == Op::RETURN
          exec_return
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
      else
        "#<obj>"
      end
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
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: arithmetic requires Integer operands"
      end
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
      rhs = @stack.pop
      lhs = @stack.pop
      @stack.push(box_bool(lhs == rhs))
      nil
    end

    def exec_call
      m_idx = decode_signed
      # 閾値到達後はカウントを止めて以降の配列 write を省く。
      # 名前ではなく idx で出すのは @bytes 復元の文字列処理が spinel で
      # 安全に動くか未検証なため (CLAUDE.md ルール 11)。
      cnt = @jit_call_counts[m_idx]
      if cnt < JIT_HOT_THRESHOLD
        cnt += 1
        @jit_call_counts[m_idx] = cnt
        if cnt == JIT_HOT_THRESHOLD
          STDERR.puts "ZJIT: hot method detected (idx=#{m_idx})"
          if @dump_hir
            build_and_dump_hir(m_idx)
          end
        end
      end
      argc = @method_arities[m_idx]
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

      @cfp_pcs.push(@pc)
      @cfp_bases.push(@cur_base)
      @cur_base = new_base
      @pc = @method_pcs[m_idx]
      nil
    end

    def exec_return
      v = @stack.pop
      # 自スコープのローカル領域を破棄 (caller の base に戻す)。
      while @locals.length > @cur_base
        @locals.pop
      end
      @cur_base = @cfp_bases.pop
      @pc = @cfp_pcs.pop
      @stack.push(v)
      nil
    end

    def exec_compare(op)
      rhs = @stack.pop
      lhs = @stack.pop
      if !fixnum?(lhs) || !fixnum?(rhs)
        raise "TypeError: comparison requires Integer operands"
      end
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
        elsif op == Op::PUTS
          v = sstack.pop
          hir_id = emit_hir(HirOp::PUTS, v, 0, 0)
          # bytecode の PUTS は nil を push するのでそれに合わせる。
          nil_id = emit_hir(HirOp::LOAD_CONST, HirConstTag::NIL, 0, 0)
          sstack.push(nil_id)
        elsif op == Op::CALL
          callee_idx = decode_signed
          arity = @method_arities[callee_idx]
          # underflow から `nil` が @hir_call_args (IntArray) に混入するのを防ぐ。
          if sstack.length < arity
            raise "JIT-2 bug: CALL underflow (need #{arity}, have #{sstack.length}) at pc=#{bc_pc}"
          end
          args_start = @hir_call_args.length
          ai = sstack.length - arity
          ae = sstack.length
          while ai < ae
            @hir_call_args.push(sstack[ai])
            ai += 1
          end
          ai = 0
          while ai < arity
            sstack.pop
            ai += 1
          end
          hir_id = emit_hir(HirOp::CALL, callee_idx, args_start, arity)
          sstack.push(hir_id)
        elsif op == Op::RETURN
          v = sstack.pop
          hir_id = emit_hir(HirOp::RETURN, v, 0, 0)
        else
          raise "JIT-2 bug: unknown opcode #{op} at pc=#{bc_pc}"
        end
        if hir_id >= 0
          bc_to_hir[bc_pc] = hir_id
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

      dump_hir(m_idx, "raw")
      optimize_hir
      dump_hir(m_idx, "optimized")
      nil
    end

    def emit_hir(kind, op0, op1, op2)
      @hir_kind.push(kind)
      @hir_op0.push(op0)
      @hir_op1.push(op1)
      @hir_op2.push(op2)
      @hir_deleted.push(0)
      @hir_kind.length - 1
    end

    def dump_hir(m_idx, label)
      STDERR.puts "ZJIT HIR (#{label}) for method idx=#{m_idx}:"
      i = 0
      while i < @hir_kind.length
        if @hir_deleted[i] == 0
          STDERR.puts "  v#{i} = #{format_hir_insn(i)}"
        end
        i += 1
      end
      nil
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
      elsif kind == HirOp::STORE_LOCAL
        result = "StoreLocal slot=#{op0}, v#{op1}"
      elsif kind == HirOp::POP
        result = "Pop"
      elsif kind == HirOp::JUMP
        result = "Jump v#{op0}"
      elsif kind == HirOp::JUMP_IF_FALSE
        result = "JumpIfFalse v#{op0}, v#{op1}"
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
      elsif kind == HirOp::CALL
        result = format_call_insn(op0, op1, op2)
      elsif kind == HirOp::RETURN
        result = "Return v#{op0}"
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

    # ============================================================
    # JIT-3a: HIR 最適化パス
    # ============================================================

    def optimize_hir
      pass_fold_constants
      pass_eliminate_dead_code
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
      elsif arith_kind?(kind) || compare_kind?(kind)
        use_counts[@hir_op0[i]] += 1
        use_counts[@hir_op1[i]] += 1
      elsif kind == HirOp::PUTS
        use_counts[@hir_op0[i]] += 1
      elsif kind == HirOp::CALL
        args_start = @hir_op1[i]
        arity      = @hir_op2[i]
        j = 0
        while j < arity
          use_counts[@hir_call_args[args_start + j]] += 1
          j += 1
        end
      elsif kind == HirOp::RETURN
        use_counts[@hir_op0[i]] += 1
      end
      # LOAD_CONST / LOAD_LOCAL / POP は op が即値またはなしなので加算不要。
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
      end
      result
    end
  end
end
