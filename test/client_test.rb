# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/flowspeech"

class FlowSpeechClientTest < Minitest::Test
  Response = Struct.new(:code, :body, :headers) do
    def [](name)
      headers[name]
    end
  end

  def test_synthesize_sends_bearer_token_and_decodes_audio
    captured = nil
    transport = lambda do |uri, request|
      captured = [uri, request]
      Response.new(
        "200",
        JSON.generate(
          code: 0,
          message: "ok",
          data: {
            mimeType: "audio/L16;rate=24000",
            audioBase64: ["audio bytes"].pack("m0"),
            sampleRate: 24_000,
            numChannels: 1,
            bitsPerSample: 16
          }
        ),
        {}
      )
    end

    client = FlowSpeech::Client.new(api_key: "test-key", transport: transport)
    audio = client.synthesize(text: "Hello", speakers: [{ voice_name: "Kore" }])

    uri, request = captured
    assert_equal "/api/ai/text-to-speech", uri.path
    assert_equal "Bearer test-key", request["Authorization"]
    assert_equal "audio bytes", audio.bytes
    assert_equal 24_000, audio.sample_rate

    payload = JSON.parse(request.body)
    assert_equal "Hello", payload["text"]
    assert_equal [{ "voiceName" => "Kore" }], payload["speakers"]
  end

  def test_multi_speaker_payload
    request_body = nil
    transport = lambda do |_uri, request|
      request_body = JSON.parse(request.body)
      Response.new(
        "200",
        JSON.generate(
          code: 0,
          message: "ok",
          data: {
            mimeType: "audio/L16;rate=24000",
            audioBase64: ["x"].pack("m0"),
            sampleRate: 24_000,
            numChannels: 1,
            bitsPerSample: 16
          }
        ),
        {}
      )
    end

    FlowSpeech::Client.new(api_key: "test-key", transport: transport).synthesize(
      text: "Host: Hello\nGuest: Hi",
      speakers: [
        { speaker: "Host", voice_name: "Charon" },
        { speaker: "Guest", voice_name: "Kore" }
      ]
    )

    assert_equal(
      [
        { "voiceName" => "Charon", "speaker" => "Host" },
        { "voiceName" => "Kore", "speaker" => "Guest" }
      ],
      request_body["speakers"]
    )
  end

  def test_quota
    transport = lambda do |uri, request|
      assert_equal "/api/ai/text-to-speech/quota", uri.path
      assert_instance_of Net::HTTP::Get, request
      Response.new(
        "200",
        JSON.generate(code: 0, message: "ok", data: { quota: { remaining: 900 } }),
        {}
      )
    end

    quota = FlowSpeech::Client.new(api_key: "test-key", transport: transport).quota
    assert_equal 900, quota["remaining"]
  end

  def test_api_error_exposes_retry_metadata
    transport = lambda do |_uri, _request|
      Response.new(
        "429",
        JSON.generate(
          code: 429,
          message: "Rate limit exceeded",
          data: { errorCode: "RATE_LIMIT", retryable: true }
        ),
        { "Retry-After" => "10" }
      )
    end

    error = assert_raises(FlowSpeech::APIError) do
      FlowSpeech::Client.new(api_key: "test-key", transport: transport).quota
    end

    assert_equal 429, error.status
    assert_equal "RATE_LIMIT", error.error_code
    assert error.retryable
    assert_equal "10", error.retry_after
  end

  def test_requires_api_key
    assert_raises(ArgumentError) { FlowSpeech::Client.new(api_key: "") }
  end
end

