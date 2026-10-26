# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "securerandom"
require "time"
require "timeout"
require "uri"
require_relative "wav"

module FlowSpeech
  class Error < StandardError
    attr_accessor :request_id, :job_id
  end
  class DeadlineError < Error; end
  class JobError < Error
    attr_reader :status, :error_code, :result_deleted
    def initialize(job)
      @status = job["status"]
      @error_code = job["error"].is_a?(Hash) ? job["error"]["code"] : nil
      @result_deleted = job["resultDeleted"] == true
      super(@result_deleted ? "Audio result was deleted (resultDeleted=true)" : "Job #{@status}: #{@error_code}")
      @request_id, @job_id = job["requestId"], job["id"]
    end
  end
  class APIError < Error
    attr_reader :status, :code, :error_code, :retryable, :retry_after, :trace_id
    def initialize(message, status:, code: nil, error_code: nil, retryable: false, retry_after: nil, trace_id: nil)
      super(message)
      @status, @code, @error_code = status, code, error_code || code
      @retryable, @retry_after, @trace_id = retryable, retry_after, trace_id
    end
  end

  class Audio
    attr_reader :mime_type, :audio_base64, :quota, :sample_rate, :num_channels,
                :bits_per_sample, :job_id, :request_id, :usage
    def initialize(data)
      @mime_type, @audio_base64 = data.fetch("mimeType"), data.fetch("audioBase64")
      @quota, @sample_rate = data["quota"], data.fetch("sampleRate")
      @num_channels, @bits_per_sample = data.fetch("numChannels"), data.fetch("bitsPerSample")
      @job_id, @request_id, @usage = data["jobId"], data["requestId"], data["usage"]
    end
    def bytes
      Base64.strict_decode64(audio_base64)
    rescue ArgumentError
      raise Error, "Invalid local base64 audio"
    end
    def write(path)
      File.binwrite(path, bytes)
      path
    end
  end

  class Client
    DEFAULT_BASE_URL = "https://flowspeech.io"
    JOBS = "/api/v1/tts/jobs"
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    PENDING = %w[queued running merging settling].freeze
    Response = Struct.new(:code, :body, :headers) do
      def [](name)
        headers[name.downcase]
      end
    end

    # Transports are trusted injection points. A download transport must not
    # add authentication, cookies or redirect handling of its own.
    def initialize(api_key: ENV["FLOWSPEECH_API_KEY"], base_url: DEFAULT_BASE_URL,
                   open_timeout: 10, read_timeout: 30, timeout: 600,
                   poll_interval: 5, max_retries: 2, max_download_bytes: 64 * 1024 * 1024,
                   transport: nil, download_transport: nil, sleeper: nil)
      unless api_key.is_a?(String) && !api_key.empty? && !api_key.match?(/\s/)
        raise ArgumentError, "api_key must be nonempty and contain no whitespace"
      end
      @api_key = api_key
      @base_url = safe_url(base_url)
      unless ["", "/"].include?(@base_url.path) && !@base_url.query
        raise ArgumentError, "base_url must be an origin"
      end
      [open_timeout, read_timeout, timeout, poll_interval].each do |value|
        raise ArgumentError, "timeouts must be finite and positive" unless value.is_a?(Numeric) && value.finite? && value > 0
      end
      raise ArgumentError, "poll_interval must be at least five seconds" if poll_interval < 5
      raise ArgumentError, "max_retries must be 0..10" unless max_retries.is_a?(Integer) && (0..10).cover?(max_retries)
      unless max_download_bytes.is_a?(Integer) && (1..(1 << 30)).cover?(max_download_bytes)
        raise ArgumentError, "max_download_bytes must be 1..1073741824"
      end
      @open_timeout, @read_timeout, @timeout = open_timeout, read_timeout, timeout
      @poll_interval, @max_retries, @max_download_bytes = poll_interval, max_retries, max_download_bytes
      @transport, @download_transport = transport, download_transport
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def quota
      quota_details.fetch("quota")
    end

    # Preserves both entitlement (contract) and subscription (server alias).
    def quota_details
      operation do |deadline|
        data = request(:get, "/api/v1/quota", deadline: deadline).first
        raise Error, "Missing quota" unless data["quota"].is_a?(Hash)
        data
      end
    end

    def voices
      operation do |deadline|
        data = request(:get, "/api/v1/voices", deadline: deadline).first
        raise Error, "Missing voices" unless data["voices"].is_a?(Array)
        data["voices"]
      end
    end

    def create_job(text: nil, speakers: nil, voice_name: "Kore", segments: nil, original_text: nil, request_id: nil)
      input = normalize_input(text, speakers, voice_name, segments, original_text)
      id = checked_id(request_id || SecureRandom.uuid)
      operation(request_id: id) { |deadline| submit(input, id, deadline) }
    end

    def get_job(id)
      checked_id(id)
      operation(job_id: id) { |deadline| get(id, deadline) }
    end

    def find_job(request_id)
      checked_id(request_id)
      operation(request_id: request_id) do |deadline|
        job = job_request(:get, "#{JOBS}?requestId=#{request_id}", deadline: deadline)
        match_request(job, request_id)
      end
    end

    def cancel_job(id)
      checked_id(id)
      operation(job_id: id) do |deadline|
        job = job_request(:post, "#{JOBS}/#{id}/cancel", deadline: deadline)
        raise Error, "Job ID mismatch" unless job["id"].casecmp(id).zero?
        job
      end
    end

    def wait_job(job)
      validate_job(job)
      operation(request_id: job["requestId"], job_id: job["id"]) { |deadline| await_job(job, deadline) }
    end

    # Retrying this method never creates a new job.
    def download(job)
      validate_job(job)
      operation(request_id: job["requestId"], job_id: job["id"]) { |deadline| download_bytes(job, deadline) }
    end

    def synthesize(text: nil, speakers: nil, voice_name: "Kore", segments: nil, original_text: nil, request_id: nil)
      input = normalize_input(text, speakers, voice_name, segments, original_text)
      id = checked_id(request_id || SecureRandom.uuid)
      job = nil
      operation(request_id: id) do |deadline|
        job = submit(input, id, deadline)
        job = await_job(job, deadline)
        bytes = download_bytes(job, deadline)
        Audio.new(job["result"].merge("audioBase64" => Base64.strict_encode64(bytes),
          "numChannels" => job["result"]["channels"], "jobId" => job["id"], "requestId" => id, "usage" => job["usage"]))
      end
    rescue Error => error
      error.job_id ||= job && job["id"]
      raise
    end

    private

    def normalize_input(text, speakers, voice, segments, original)
      raise ArgumentError, "original_text is unsupported by v1" unless original.nil?
      unless segments.nil?
        unless segments.is_a?(Array) && !segments.empty? && text.nil? && speakers.nil?
          raise ArgumentError, "Use nonempty segments without text or speakers"
        end
        return { "mode" => "multi", "segments" => segments.map { |s| normalize_segment(s) } }
      end
      if speakers
        unless speakers.is_a?(Array) && speakers.length == 1
          raise ArgumentError, "Use explicit segments for multiple speakers"
        end
        s = normalize_keys(speakers.first, %w[voice_name voiceName])
        voice = s["voiceName"] || s["voice_name"]
      end
      required_string(text, "text")
      required_string(voice, "voiceName")
      { "mode" => "single", "text" => text, "voiceName" => voice }
    end

    def normalize_segment(segment)
      s = normalize_keys(segment, %w[speaker text voiceName voice_name])
      s["voiceName"] ||= s.delete("voice_name")
      %w[speaker text voiceName].each { |key| required_string(s[key], key) }
      s
    end

    def normalize_keys(value, allowed)
      raise ArgumentError, "Expected a hash" unless value.is_a?(Hash)
      result = {}
      value.each do |key, v|
        key = key.to_s
        raise ArgumentError, "Unsupported or duplicate input field: #{key}" unless allowed.include?(key) && !result.key?(key)
        result[key] = v
      end
      if result.key?("voiceName") && result.key?("voice_name")
        raise ArgumentError, "Specify only one voice name field"
      end
      result
    end

    def required_string(value, name)
      raise ArgumentError, "#{name} must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
    end

    def checked_id(id)
      raise ArgumentError, "ID must be a UUID" unless id.is_a?(String) && UUID.match?(id)
      id
    end

    def safe_url(raw)
      uri = URI(raw)
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.fragment &&
             (uri.scheme == "https" || (uri.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.hostname)))
        raise ArgumentError, "URL must be HTTPS without credentials or fragment; HTTP loopback is allowed for tests"
      end
      uri
    rescue URI::InvalidURIError, TypeError
      raise ArgumentError, "Invalid URL"
    end

    def operation(request_id: nil, job_id: nil)
      deadline = monotonic + @timeout
      Timeout.timeout(@timeout, DeadlineError) { yield deadline }
    rescue Error => error
      error.request_id ||= request_id
      error.job_id ||= job_id
      raise
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining(deadline)
      value = deadline - monotonic
      raise DeadlineError, "Operation deadline exceeded" if value <= 0
      value
    end

    def pause(raw, deadline)
      delay = @poll_interval
      if raw.to_s.match?(/\A\d+\z/)
        delay = [delay, raw.to_i].max
      elsif raw
        begin
          delay = [delay, Time.httpdate(raw) - Time.now].max
        rescue ArgumentError
          # Invalid Retry-After uses the conservative polling interval.
        end
      end
      raise DeadlineError, "Retry or poll wait would exceed operation deadline" if delay >= remaining(deadline)
      @sleeper.call(delay)
      remaining(deadline)
    end

    def submit(input, id, deadline)
      job = job_request(:post, JOBS, body: JSON.generate("input" => input), id: id, deadline: deadline)
      match_request(job, id)
    end

    def match_request(job, id)
      if job["requestId"] && !job["requestId"].casecmp(id).zero?
        raise Error, "Request ID mismatch"
      end
      job["requestId"] = id
      job
    end

    def get(id, deadline)
      job = job_request(:get, "#{JOBS}/#{id}", deadline: deadline)
      raise Error, "Job ID mismatch" unless job["id"].casecmp(id).zero?
      job
    end

    def job_request(method, path, body: nil, id: nil, deadline:)
      job, retry_after = request(method, path, body: body, id: id, deadline: deadline)
      validate_job(job)
      job["retryAfter"] = retry_after
      job
    end

    def validate_job(job)
      unless job.is_a?(Hash) && job["id"].is_a?(String) && UUID.match?(job["id"])
        raise Error, "Missing or invalid job ID"
      end
      if job.key?("requestId") && (!job["requestId"].is_a?(String) || !UUID.match?(job["requestId"]))
        raise Error, "Invalid request ID"
      end
      if job.key?("resultDeleted") && ![true, false].include?(job["resultDeleted"])
        raise Error, "Invalid resultDeleted flag"
      end
      status = job["status"]
      raise Error, "Unknown job status" unless (PENDING + %w[success failed cancelled]).include?(status)
      return job unless status == "success"
      return job if job["resultDeleted"] == true && job["result"].nil?
      result = job["result"]
      unless job["resultDeleted"] != true && result.is_a?(Hash) && result["mimeType"] == "audio/wav" &&
             result["sampleRate"] == 24000 && result["channels"] == 1 && result["bitsPerSample"] == 16
        raise Error, "Missing or malformed WAV result"
      end
      safe_url(result["url"])
      job
    rescue ArgumentError
      raise Error, "Invalid audio URL"
    end

    def await_job(job, deadline)
      id, request_id = job["id"], job["requestId"]
      loop do
        remaining(deadline)
        if PENDING.include?(job["status"])
          pause(job["retryAfter"], deadline)
          job = get(id, deadline)
          match_request(job, request_id) if request_id
        elsif job["status"] == "success" && job["resultDeleted"] != true
          return job
        else
          raise JobError, job
        end
      end
    end

    def download_bytes(job, deadline)
      raise JobError, job unless job["status"] == "success" && job["resultDeleted"] != true
      uri = safe_url(job.fetch("result").fetch("url"))
      req = Net::HTTP::Get.new(uri)
      response = exchange(uri, req, deadline, @max_download_bytes, @download_transport)
      raise Error, "Download HTTP #{response.code}; retry download with the same job" unless response.code.to_i == 200
      Wav.validate!(response.body.to_s) { remaining(deadline) }
    rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "Audio download failed; retry download with the same job"
    end

    def request(method, path, body: nil, id: nil, deadline:)
      uri = @base_url + path
      attempts = 0
      loop do
        retry_after = nil
        begin
          req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
          req["Authorization"] = "Bearer #{@api_key}"
          req["Accept"] = "application/json"
          req["Idempotency-Key"] = id if id
          if body
            req["Content-Type"] = "application/json"
            req.body = body
          end
          response = exchange(uri, req, deadline, 1024 * 1024, @transport)
          status = response.code.to_i
          retry_after = response["Retry-After"]
          data = begin
            JSON.parse(response.body.to_s)
          rescue JSON::ParserError
            nil
          end
          if (200..299).cover?(status)
            raise Error, "Invalid JSON object response" unless data.is_a?(Hash)
            return [data, retry_after]
          end
          detail = data.is_a?(Hash) && data["error"].is_a?(Hash) ? data["error"] : {}
          error = APIError.new(detail["message"] || "HTTP #{status}", status: status,
            code: detail["code"], retryable: detail["retryable"] == true, retry_after: retry_after,
            trace_id: data.is_a?(Hash) ? data["traceId"] || response["X-Request-Id"] : response["X-Request-Id"])
          raise error unless status == 429 || (status >= 500 && error.retryable)
        rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError
          error = Error.new("API transport failed")
        end
        raise error if attempts >= @max_retries
        attempts += 1
        pause(retry_after, deadline)
      end
    end

    def exchange(uri, request, deadline, limit, transport)
      remaining(deadline)
      response = if transport
        transport.call(uri, request)
      else
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: [@open_timeout, remaining(deadline)].min,
          read_timeout: [@read_timeout, remaining(deadline)].min) do |http|
          http.max_retries = 0 if http.respond_to?(:max_retries=)
          result = nil
          http.request(request) do |res|
            bytes = String.new(encoding: Encoding::BINARY)
            res.read_body do |chunk|
              remaining(deadline)
              raise Error, "Response exceeds byte limit" if bytes.bytesize + chunk.bytesize > limit
              bytes << chunk
            end
            result = Response.new(res.code, bytes, res.to_hash.transform_values(&:first))
          end
          result
        end
      end
      remaining(deadline)
      raise Error, "Response exceeds byte limit" if response.body.to_s.bytesize > limit
      response
    end
  end
end
