# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"

module FlowSpeech
  class Error < StandardError; end

  class APIError < Error
    attr_reader :status, :code, :error_code, :retryable, :retry_after

    def initialize(message, status:, code: nil, error_code: nil, retryable: false, retry_after: nil)
      super(message)
      @status = status
      @code = code
      @error_code = error_code
      @retryable = retryable
      @retry_after = retry_after
    end
  end

  class Audio
    attr_reader :mime_type, :audio_base64, :quota, :sample_rate, :num_channels, :bits_per_sample

    def initialize(data)
      @mime_type = data.fetch("mimeType")
      @audio_base64 = data.fetch("audioBase64")
      @quota = data["quota"]
      @sample_rate = data.fetch("sampleRate")
      @num_channels = data.fetch("numChannels")
      @bits_per_sample = data.fetch("bitsPerSample")
    end

    def bytes
      Base64.strict_decode64(audio_base64)
    rescue ArgumentError => e
      raise Error, "FlowSpeech returned invalid base64 audio: #{e.message}"
    end

    def write(path)
      File.binwrite(path, bytes)
      path
    end
  end

  class Client
    DEFAULT_BASE_URL = "https://flowspeech.io"

    def initialize(api_key: ENV["FLOWSPEECH_API_KEY"], base_url: DEFAULT_BASE_URL,
                   open_timeout: 10, read_timeout: 90, transport: nil)
      @api_key = api_key.to_s.strip
      @base_url = URI(base_url)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @transport = transport

      raise ArgumentError, "api_key is required" if @api_key.empty?
      unless @base_url.is_a?(URI::HTTP) && @base_url.host
        raise ArgumentError, "base_url must be an HTTP or HTTPS URL"
      end
    end

    def quota
      request(:get, "/api/ai/text-to-speech/quota").fetch("quota")
    end

    def synthesize(text:, speakers: [{ voice_name: "Kore" }], original_text: nil)
      raise ArgumentError, "text is required" if text.to_s.strip.empty?

      normalized_speakers = Array(speakers).map { |speaker| normalize_speaker(speaker) }
      raise ArgumentError, "at least one speaker is required" if normalized_speakers.empty?

      data = request(
        :post,
        "/api/ai/text-to-speech",
        text: text,
        originalText: original_text || text,
        speakers: normalized_speakers
      )
      raise Error, "FlowSpeech response did not include audio" if data["audioBase64"].to_s.empty?

      Audio.new(data)
    end

    private

    def normalize_speaker(speaker)
      input = speaker.respond_to?(:to_h) ? speaker.to_h : {}
      voice_name = input[:voice_name] || input["voice_name"] || input[:voiceName] || input["voiceName"]
      raise ArgumentError, "every speaker requires voice_name" if voice_name.to_s.strip.empty?

      result = { voiceName: voice_name }
      label = input[:speaker] || input["speaker"]
      result[:speaker] = label unless label.to_s.strip.empty?
      result
    end

    def request(method, path, payload = nil)
      uri = @base_url + path
      http_request = build_request(method, uri, payload)
      response = @transport ? @transport.call(uri, http_request) : perform(uri, http_request)
      parsed = parse_json(response.body)

      unless response.code.to_i.between?(200, 299)
        error_data = parsed["data"].is_a?(Hash) ? parsed["data"] : {}
        message = parsed["message"].to_s.strip
        message = "FlowSpeech request failed with HTTP #{response.code}" if message.empty?
        raise APIError.new(
          message,
          status: response.code.to_i,
          code: parsed["code"],
          error_code: error_data["errorCode"],
          retryable: error_data["retryable"] == true,
          retry_after: response["Retry-After"]
        )
      end

      unless parsed["code"] == 0 && parsed["data"].is_a?(Hash)
        raise Error, parsed["message"].to_s.empty? ? "Unexpected FlowSpeech response" : parsed["message"]
      end

      parsed["data"]
    end

    def build_request(method, uri, payload)
      request_class = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      request = request_class.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"
      if payload
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
      end
      request
    end

    def perform(uri, request)
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(request) }
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError => e
      raise Error, "FlowSpeech returned invalid JSON: #{e.message}"
    end
  end
end

