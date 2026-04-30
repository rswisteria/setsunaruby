module Setsunaruby
  # Signed LEB128 エンコード/デコード。
  # spinel の `def self.xxx` 型推論バグ回避のためインスタンスメソッドにしている。
  class Leb128
    def encode_signed(n, out)
      more = true
      while more
        byte = n & 0x7f
        n = n >> 7
        if (n == 0 && (byte & 0x40) == 0) || (n == -1 && (byte & 0x40) != 0)
          more = false
        else
          byte = byte | 0x80
        end
        out.push(byte)
      end
    end

    # bytes: Array[Integer], pc: Integer
    # 戻り値: [decoded_int, next_pc] (2要素 IntArray)
    def decode_signed(bytes, pc)
      result = 0
      shift = 0
      done = false
      while !done
        b = bytes[pc]
        pc += 1
        result = result | ((b & 0x7f) << shift)
        shift += 7
        if (b & 0x80) == 0
          if (b & 0x40) != 0
            result = result | (-1 << shift)
          end
          done = true
        end
      end
      [result, pc]
    end
  end
end
