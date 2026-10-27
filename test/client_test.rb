# frozen_string_literal: true

require "minitest/autorun"
require "flowspeech"
require "socket"
require_relative "wav_fixture"

class ClientTest < Minitest::Test
  include WavFixture
  ID = "b698824b-de05-486d-8833-05d5c4522a39"
  REQUEST_ID = "51382b81-9d36-49a5-994e-9b67686c6bd1"

  def response(status, data, headers = {})
    FlowSpeech::Client::Response.new(status.to_s, data.is_a?(String) ? data : JSON.generate(data), headers.transform_keys(&:downcase))
  end

  def job(status = "success")
    result = { "id" => ID, "requestId" => REQUEST_ID, "status" => status,
      "usage" => { "billableCharacters" => 5, "reservedCredits" => 0, "chargedCredits" => 5 } }
    if status == "success"
      result["result"] = { "url" => "https://audio.example.test/speech.wav", "mimeType" => "audio/wav",
        "sampleRate" => 24000, "channels" => 1, "bitsPerSample" => 16 }
    end
    result
  end

  def client(**options, &transport)
    FlowSpeech::Client.new(api_key: "fixture-key", sleeper: ->(_) {}, transport: transport, **options)
  end

  def test_lifecycle_and_single_mapping
    calls, sleeps = [], []
    statuses = %w[queued running merging settling success]
    downloader = lambda do |uri, req|
      assert_equal "audio.example.test", uri.host
      %w[Authorization Cookie Idempotency-Key].each { |header| assert_nil req[header] }
      response(200, valid_wav)
    end
    c = client(sleeper: ->(seconds) { sleeps << seconds }, download_transport: downloader) do |uri, req|
      assert_equal "Bearer fixture-key", req["Authorization"]
      if calls.empty?
        assert_equal "/api/v1/tts/jobs", uri.path
        assert_equal "POST", req.method
        assert_equal REQUEST_ID, req["Idempotency-Key"]
        assert_equal({ "input" => { "mode" => "single", "text" => "Hello", "voiceName" => "Kore" } }, JSON.parse(req.body))
      else
        assert_equal "/api/v1/tts/jobs/#{ID}", uri.path
        assert_equal "GET", req.method
      end
      calls << req
      response(202, job(statuses.shift), "Retry-After" => "7")
    end
    audio = c.synthesize(text: "Hello", speakers: [{ voice_name: "Kore" }], request_id: REQUEST_ID)
    assert_equal valid_wav, audio.bytes
    assert_equal ID, audio.job_id
    assert_equal REQUEST_ID, audio.request_id
    assert_equal 5, audio.usage["chargedCredits"]
    assert_equal "audio/wav", audio.mime_type
    assert_equal [7, 7, 7, 7], sleeps
    assert_equal 5, calls.length
  end

  def test_multi_mapping
    c = client do |_, req|
      assert_equal({ "input" => { "mode" => "multi", "segments" => [
        { "speaker" => "Alice", "text" => "Hi", "voiceName" => "Kore" },
        { "speaker" => "Bob", "text" => "Hello", "voiceName" => "Puck" }
      ] } }, JSON.parse(req.body))
      response(202, job("queued"))
    end
    c.create_job(segments: [{ speaker: "Alice", text: "Hi", voice_name: "Kore" },
      { speaker: "Bob", text: "Hello", voiceName: "Puck" }], request_id: REQUEST_ID)
  end

  def test_retries_preserve_generated_uuid_and_body
    calls, delays = [], []
    c = client(sleeper: ->(n) { delays << n }) do |_, req|
      calls << [req["Idempotency-Key"], req.body]
      raise IOError, "lost response" if calls.length == 1
      if calls.length == 2
        response(503, { error: { code: "busy", retryable: true } }, "Retry-After" => "12")
      else
        response(200, job.merge("requestId" => calls.first.first))
      end
    end
    result = c.create_job(text: "Hello")
    assert_match FlowSpeech::Client::UUID, result["requestId"]
    assert_equal 1, calls.uniq.length
    assert_equal [5, 12], delays
  end

  def test_quota_voices_recovery_cancel
    c = client do |uri, req|
      case uri.path
      when "/api/v1/quota"
        response(200, { quota: { remaining: 10, reserved: 3, available: 7 }, entitlement: { plan: "basic" }, subscription: nil, limits: { readPerMinute: 60 } })
      when "/api/v1/voices"
        response(200, { voices: [{ name: "Kore" }] })
      when "/api/v1/tts/jobs"
        assert_equal "requestId=#{REQUEST_ID}", uri.query
        response(200, job("queued"))
      when "/api/v1/tts/jobs/#{ID}/cancel"
        assert_equal "POST", req.method
        response(200, job("cancelled"))
      else
        flunk uri.to_s
      end
    end
    assert_equal 7, c.quota["available"]
    assert_equal "basic", c.quota_details["entitlement"]["plan"]
    assert_equal 60, c.quota_details["limits"]["readPerMinute"]
    assert_equal "Kore", c.voices.first["name"]
    assert_equal ID, c.find_job(REQUEST_ID)["id"]
    assert_equal "cancelled", c.cancel_job(ID)["status"]
  end

  def with_interrupted_http(status, retry_after, recover:, stall: false)
    server = TCPServer.new("127.0.0.1", 0)
    captured = []
    worker = Thread.new do
      (recover ? 2 : 1).times do |index|
        socket = server.accept
        headers = []
        while (line = socket.gets) && line != "\r\n"
          headers << line
        end
        length = headers.join[/Content-Length: (\d+)/i, 1].to_i
        captured << [headers.join[/Idempotency-Key: ([^\r]+)/i, 1], socket.read(length)]
        if index.zero?
          socket.write("HTTP/1.1 #{status} Unavailable\r\nRetry-After: #{retry_after}\r\nX-Request-Id: fixture-trace\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n10\r\n{")
          sleep 0.05 if stall
        else
          body = JSON.generate(job("queued"))
          socket.write("HTTP/1.1 202 Accepted\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        end
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}", captured
    assert worker.join(2), "mock server did not finish"
  ensure
    server.close if server
    worker.kill if worker && worker.alive?
    worker.join if worker
  end

  def test_interrupted_native_body_preserves_cooldown_uuid_and_bytes
    [429, 503].each do |status|
      ["30", (Time.now + 30).httpdate].each do |retry_after|
        with_interrupted_http(status, retry_after, recover: true) do |base, captured|
          delays = []
          c = FlowSpeech::Client.new(api_key: "fixture-key", base_url: base, read_timeout: 1,
            max_retries: 1, sleeper: ->(seconds) { delays << seconds })
          assert_equal ID, c.create_job(text: "Hello", request_id: REQUEST_ID)["id"]
          assert_equal 2, captured.length
          assert_equal captured.first, captured.last
          assert_equal REQUEST_ID, captured.first.first
          assert_equal 1, delays.length
          assert_operator delays.first, :>, 28
          assert_operator delays.first, :<=, 30
        end
      end
    end
  end

  def test_interrupted_native_body_retains_metadata_when_retries_exhausted
    [429, 503].each do |status|
      with_interrupted_http(status, "30", recover: false) do |base, _|
        c = FlowSpeech::Client.new(api_key: "fixture-key", base_url: base, read_timeout: 1, max_retries: 0)
        error = assert_raises(FlowSpeech::APIError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
        assert_equal status, error.status
        assert_equal "30", error.retry_after
        assert_equal "fixture-trace", error.trace_id
        assert_equal REQUEST_ID, error.request_id
        assert error.retryable
      end
    end
  end

  def test_error_metadata_and_retry_bound
    [401, 403, 409, 429, 503].each do |status|
      calls = 0
      c = client do |_, _|
        calls += 1
        response(status, { error: { code: "fixture_error", message: "Rejected", retryable: true }, traceId: "fixture-trace" }, "Retry-After" => "9")
      end
      error = assert_raises(FlowSpeech::APIError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
      assert_equal status, error.status
      assert_equal "fixture_error", error.error_code
      assert_equal "fixture-trace", error.trace_id
      assert_equal REQUEST_ID, error.request_id
      assert_equal "9", error.retry_after
      assert_equal [429, 503].include?(status) ? 3 : 1, calls
    end
  end

  def test_reflected_api_error_metadata_is_safe_to_log
    ["fixture-key", "prefix-fixture-key-suffix", "https://audio.example.test/private?signature=CANARY"].each do |unsafe|
      c = client { response(401, { error: { code: unsafe, message: unsafe, retryable: false }, traceId: unsafe }, "X-Request-Id" => unsafe) }
      error = assert_raises(FlowSpeech::APIError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
      refute_includes [error.to_s, error.inspect, error.code, error.trace_id].join(" "), unsafe
      assert_equal "api_error", error.code
      assert_nil error.trace_id
      assert_nil error.cause
      assert_equal REQUEST_ID, error.request_id
    end
  end

  def test_reflected_terminal_error_is_safe_to_log
    ["fixture-key", "prefix-fixture-key-suffix", "https://audio.example.test/private?signature=CANARY"].each do |unsafe|
      c = client { flunk "No request expected" }
      failed = job("failed").merge("error" => { "code" => unsafe, "message" => unsafe })
      error = assert_raises(FlowSpeech::JobError) { c.wait_job(failed) }
      refute_includes [error.to_s, error.inspect, error.error_code].join(" "), unsafe
      assert_equal REQUEST_ID, error.request_id
      assert_equal ID, error.job_id
    end
  end

  def test_download_cause_chain_does_not_expose_private_url
    private_url = "https://audio.example.test/private?signature=CANARY"
    c = client(download_transport: ->(_, _) { raise IOError, "Failed URL: #{private_url}" }) { flunk "No API request expected" }
    error = assert_raises(FlowSpeech::Error) { c.download(job) }
    refute_includes [error.to_s, error.inspect, error.full_message].join(" "), private_url
    assert_nil error.cause
    assert_equal REQUEST_ID, error.request_id
    assert_equal ID, error.job_id
  end

  def test_interrupted_permanent_api_failure_never_retries
    [302, 400, 401, 403, 404, 409, 422].each do |status|
      with_interrupted_http(status, "30", recover: false) do |base, captured|
        delays = []
        c = FlowSpeech::Client.new(api_key: "fixture-key", base_url: base, read_timeout: 1,
          max_retries: 2, sleeper: ->(seconds) { delays << seconds })
        error = assert_raises(FlowSpeech::APIError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
        assert_equal status, error.status
        assert_equal "30", error.retry_after
        assert_equal REQUEST_ID, error.request_id
        refute error.retryable
        assert_empty delays
        assert_equal 1, captured.length
      end
    end
  end

  def test_interrupted_auth_download_never_retries_or_calls_api
    [401, 403].each do |status|
      with_interrupted_http(status, "30", recover: false) do |base, captured|
        c = FlowSpeech::Client.new(api_key: "fixture-key", read_timeout: 1, max_retries: 2,
          transport: ->(_, _) { flunk "Download must not call API" }, sleeper: ->(_) { flunk "Download must not retry" })
        audio_job = job
        audio_job["result"]["url"] = "#{base}/audio"
        error = assert_raises(FlowSpeech::Error) { c.download(audio_job) }
        assert_equal ID, error.job_id
        assert_equal REQUEST_ID, error.request_id
        assert_equal 1, captured.length
        assert_nil captured.first.first
      end
    end
  end

  def test_native_auth_body_timeout_never_retries
    [401, 403].each do |status|
      with_interrupted_http(status, "30", recover: false, stall: true) do |base, captured|
        c = FlowSpeech::Client.new(api_key: "fixture-key", base_url: base, read_timeout: 0.01,
          max_retries: 2, sleeper: ->(_) { flunk "Known auth error must not retry" })
        error = assert_raises(FlowSpeech::APIError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
        assert_equal status, error.status
        assert_equal "30", error.retry_after
        assert_equal REQUEST_ID, error.request_id
        refute error.retryable
        assert_equal 1, captured.length
      end
    end
  end

  def test_terminal_and_deleted_jobs
    c = client { flunk "No HTTP expected" }
    %w[failed cancelled].each do |status|
      error = assert_raises(FlowSpeech::JobError) { c.wait_job(job(status).merge("error" => { "code" => "fixture_failure" })) }
      assert_equal status, error.status
      assert_equal "fixture_failure", error.error_code
      assert_equal ID, error.job_id
    end
    deleted = job.merge("result" => nil, "resultDeleted" => true)
    error = assert_raises(FlowSpeech::JobError) { c.wait_job(deleted) }
    assert error.result_deleted
    assert_raises(FlowSpeech::JobError) { c.download(deleted) }
  end

  def test_malformed_responses
    [nil, [], {}, { "id" => ID, "status" => "alien" }, job.merge("result" => nil),
     job.merge("result" => { "url" => "https://example.test" }), job.merge("id" => "../escape"),
     job.merge("result" => job["result"].merge("url" => "https://user:pass@example.test"))].each do |value|
      c = client { response(200, JSON.generate(value)) }
      assert_raises(FlowSpeech::Error) { c.get_job(ID) }
    end
    c = client { response(200, "not json") }
    assert_raises(FlowSpeech::Error) { c.quota }
  end

  def test_download_failure_and_bounds_do_not_create_again
    calls = 0
    c = client(download_transport: ->(_, _) { response(503, "unavailable") }) { calls += 1; response(200, job) }
    error = assert_raises(FlowSpeech::Error) { c.synthesize(text: "Hello", request_id: REQUEST_ID) }
    assert_equal 1, calls
    assert_equal ID, error.job_id
    assert_equal REQUEST_ID, error.request_id
    c = client(max_download_bytes: 2, download_transport: ->(_, _) { response(200, "123") }) { flunk "No create expected" }
    assert_raises(FlowSpeech::Error) { c.download(job) }
  end

  def test_redirects_are_not_followed
    calls = 0
    c = client { calls += 1; response(302, "redirect", "Location" => "https://elsewhere.test") }
    assert_raises(FlowSpeech::APIError) { c.quota }
    assert_equal 1, calls
    c = client(download_transport: ->(_, req) { assert_nil req["Authorization"]; response(302, "redirect", "Location" => "https://elsewhere.test") })
    assert_raises(FlowSpeech::Error) { c.download(job) }
  end

  def test_total_deadline_and_http_date_retry_after
    c = client(timeout: 0.03) { sleep 0.2; response(200, job) }
    error = assert_raises(FlowSpeech::DeadlineError) { c.create_job(text: "Hi", request_id: REQUEST_ID) }
    assert_equal REQUEST_ID, error.request_id
    c = client(timeout: 0.03) { response(202, job("queued")) }
    assert_raises(FlowSpeech::DeadlineError) { c.synthesize(text: "Hi", request_id: REQUEST_ID) }
    delays, calls = [], 0
    c = client(sleeper: ->(n) { delays << n }) do |_, _|
      calls += 1
      calls == 1 ? response(429, { error: { code: "rate", retryable: true } }, "Retry-After" => (Time.now + 20).httpdate) : response(200, { voices: [] })
    end
    c.voices
    assert_operator delays.first, :>, 18
    assert_operator delays.first, :<=, 20
  end

  def test_input_and_configuration_validation
    c = client { flunk "Invalid input reached network" }
    [{}, { text: " " }, { text: "Hi", original_text: "Hi" }, { text: "Hi", speakers: [] },
     { text: "Hi", speakers: [{ speaker: "A", voice_name: "Kore" }] },
     { segments: [] }, { segments: [{ speaker: "A", text: "Hi", voice_name: "Kore", speed: 2 }] },
     { text: "Hi", segments: [{ speaker: "A", text: "Hi", voiceName: "Kore" }] },
     { text: "Hi", request_id: "invalid" }].each { |args| assert_raises(ArgumentError) { c.create_job(**args) } }
    assert_raises(ArgumentError) { c.get_job("../escape") }
    ["", "bad\r\nkey", "has space"].each { |key| assert_raises(ArgumentError) { FlowSpeech::Client.new(api_key: key) } }
    %w[file:///tmp/x http://example.test https://user:pass@example.test https://example.test/api].each do |url|
      assert_raises(ArgumentError) { client(base_url: url) }
    end
    [{ timeout: 0 }, { poll_interval: 1 }, { max_retries: -1 }, { max_download_bytes: 0 }].each do |args|
      assert_raises(ArgumentError) { client(**args) }
    end
  end

  def test_real_http_streaming_limits_and_redirect_refusal
    server = TCPServer.new("127.0.0.1", 0)
    captured = []
    worker = Thread.new do
      2.times do |index|
        socket = server.accept
        headers = []
        while (line = socket.gets) && line != "\r\n"
          headers << line
        end
        captured << headers.join
        if index.zero?
          socket.write("HTTP/1.1 302 Found\r\nLocation: /destination\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
          socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nABCD\r\n0\r\n\r\n")
        end
        socket.close
      end
    end
    base = "http://127.0.0.1:#{server.addr[1]}"
    c = FlowSpeech::Client.new(api_key: "fixture-key", base_url: base, max_download_bytes: 3)
    error = assert_raises(FlowSpeech::APIError) { c.quota }
    assert_equal 302, error.status
    audio_job = job
    audio_job["result"]["url"] = "#{base}/audio"
    error = assert_raises(FlowSpeech::Error) { c.download(audio_job) }
    assert_match(/byte limit/, error.message)
    worker.join(2)
    assert_equal 2, captured.length
    assert_match(/Authorization: Bearer fixture-key/i, captured.first)
    refute_match(/Authorization:|Cookie:|Idempotency-Key:/i, captured.last)
  ensure
    server.close if server
    worker.kill if worker && worker.alive?
  end

  def test_wav_preserves_valid_pcm_and_unknown_chunks
    [valid_wav, wav_file(wav_chunk("JUNK", "123"), wav_chunk("fmt ", wav_format + "\0\0"),
      wav_chunk("LIST", "a"), wav_chunk("data", "\0\0\1\0"), wav_chunk("JUNK", ""))].each do |bytes|
      c = client(download_transport: ->(_, _) { response(200, bytes) }) { flunk "No API request expected" }
      assert_equal bytes, c.download(job)
    end
  end

  def test_malformed_wav_downloads_are_rejected_with_recovery_ids
    corrupt_wavs.each do |name, bytes|
      c = client(download_transport: ->(_, _) { response(200, bytes) }) { flunk "No API request expected" }
      error = assert_raises(FlowSpeech::Error, name) { c.download(job) }
      assert_match(/Invalid WAV/, error.message, name)
      assert_equal ID, error.job_id
      assert_equal REQUEST_ID, error.request_id
    end
  end

  def test_every_truncated_wav_prefix_is_rejected
    bytes = valid_wav
    bytes.bytesize.times do |length|
      assert_raises(FlowSpeech::Error, "#{length}-byte prefix") { FlowSpeech::Wav.validate!(bytes.byteslice(0, length)) }
    end
    assert_raises(FlowSpeech::DeadlineError) do
      FlowSpeech::Wav.validate!(bytes) { raise FlowSpeech::DeadlineError, "Parsing deadline exceeded" }
    end
  end

  def test_corrupt_wav_never_resubmits_and_download_can_be_retried
    submissions, downloads = 0, 0
    c = client(download_transport: ->(_, _) { downloads += 1; response(200, downloads == 1 ? "<html>bad</html>" : valid_wav) }) do
      submissions += 1
      response(200, job)
    end
    error = assert_raises(FlowSpeech::Error) { c.synthesize(text: "Hello", request_id: REQUEST_ID) }
    assert_equal ID, error.job_id
    assert_equal REQUEST_ID, error.request_id
    assert_equal valid_wav, c.download(job)
    assert_equal 1, submissions
    assert_equal 2, downloads
  end
end
