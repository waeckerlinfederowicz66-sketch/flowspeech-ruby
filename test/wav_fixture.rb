# frozen_string_literal: true

module WavFixture
  def wav_format
    [1, 1, 24000, 48000, 2, 16].pack("vvVVvv")
  end
  def wav_chunk(tag, payload)
    tag.b + [payload.bytesize].pack("V") + payload.b + (payload.bytesize.odd? ? "\0" : "")
  end
  def wav_file(*chunks)
    body = "WAVE".b + chunks.join.b
    "RIFF".b + [body.bytesize].pack("V") + body
  end
  def valid_wav
    wav_file(wav_chunk("fmt ", wav_format), wav_chunk("data", [0, 1].pack("s<*")))
  end
  def corrupt_wavs
    f, d = wav_chunk("fmt ", wav_format), wav_chunk("data", [0, 1].pack("s<*"))
    bad = {
      "empty" => "", "html" => "<html>not audio</html>", "magic only" => wav_file("\0" * 32),
      "missing format" => wav_file(d), "missing data" => wav_file(f),
      "empty data" => wav_file(f, wav_chunk("data", "")), "odd data" => wav_file(f, wav_chunk("data", "123")),
      "data before format" => wav_file(d, f), "duplicate format" => wav_file(f, f, d), "duplicate data" => wav_file(f, d, d),
      "short format" => wav_file(wav_chunk("fmt ", wav_format.byteslice(0, 15)), d),
      "invalid extension" => wav_file(wav_chunk("fmt ", wav_format + [1].pack("v")), d),
      "partial chunk header" => wav_file(f, d, "ABC"),
      "chunk overflow" => wav_file(f, d, "JUNK" + [0xffffffff].pack("V")),
      "missing padding" => wav_file(f, d, "JUNK" + [1].pack("V") + "a")
    }
    { "float" => [0, 3, "v"], "stereo" => [2, 2, "v"], "sample rate" => [4, 44100, "V"],
      "byte rate" => [8, 96000, "V"], "block alignment" => [12, 4, "v"], "bit depth" => [14, 8, "v"] }.each do |name, change|
      format = wav_format
      offset, value, type = change
      encoded = [value].pack(type)
      format[offset, encoded.bytesize] = encoded
      bad[name] = wav_file(wav_chunk("fmt ", format), d)
    end
    { "riff length too big" => [4, [4096].pack("V")], "riff length too small" => [4, [4].pack("V")],
      "wrong RIFF" => [0, "RIFX"], "wrong WAVE" => [8, "HTML"], "data length too big" => [40, [6].pack("V")] }.each do |name, change|
      bytes = valid_wav
      offset, replacement = change
      bytes[offset, replacement.bytesize] = replacement
      bad[name] = bytes
    end
    bad["trailing bytes"] = valid_wav + "\0"
    bad
  end
end
