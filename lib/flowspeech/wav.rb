# frozen_string_literal: true

module FlowSpeech
  module Wav
    # Walk bounded chunks, preserving the original file and its sample bytes.
    def self.validate!(bytes)
      invalid = -> { raise Error, "Invalid WAV: expected complete 24000 Hz mono 16-bit PCM with nonempty aligned data" }
      invalid.call unless bytes.bytesize >= 12 && bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WAVE"
      invalid.call unless bytes.byteslice(4, 4).unpack1("V") + 8 == bytes.bytesize
      offset, format_seen, data_seen = 12, false, false
      while offset < bytes.bytesize
        yield if block_given?
        invalid.call if bytes.bytesize - offset < 8
        tag = bytes.byteslice(offset, 4)
        size = bytes.byteslice(offset + 4, 4).unpack1("V")
        start = offset + 8
        finish = start + size
        following = finish + (size & 1)
        invalid.call if following > bytes.bytesize
        case tag
        when "fmt "
          invalid.call if format_seen || data_seen || ![16, 18].include?(size)
          fields = bytes.byteslice(start, 16).unpack("vvVVvv")
          invalid.call unless fields == [1, 1, 24000, 48000, 2, 16]
          invalid.call if size == 18 && bytes.byteslice(start + 16, 2).unpack1("v") != 0
          format_seen = true
        when "data"
          invalid.call unless format_seen && !data_seen && size > 0 && size.even?
          data_seen = true
        end
        offset = following
      end
      invalid.call unless format_seen && data_seen
      yield if block_given?
      bytes
    end
  end
end
