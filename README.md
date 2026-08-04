# FlowSpeech Ruby

[![Gem Version](https://badge.fury.io/rb/flowspeech.svg)](https://rubygems.org/gems/flowspeech)
[![Tests](https://github.com/waeckerlinfederowicz66-sketch/flowspeech-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/waeckerlinfederowicz66-sketch/flowspeech-ruby/actions/workflows/test.yml)

A small Ruby client for the [FlowSpeech text to speech API](https://flowspeech.io/). It supports context-aware synthesis, multi-speaker voice assignments, quota checks, audio metadata, and structured API errors.

The gem uses only the Ruby standard library at runtime.

## Installation

Install the gem:

```bash
gem install flowspeech
```

Or add it to your Gemfile:

```ruby
gem "flowspeech", "~> 0.1"
```

Create a FlowSpeech API key, then keep it outside source control:

```bash
export FLOWSPEECH_API_KEY="your_api_key"
```

## Generate speech

```ruby
require "flowspeech"

client = FlowSpeech::Client.new
audio = client.synthesize(
  text: "Welcome. [cheerfully] Let's make this sound natural.",
  speakers: [{ voice_name: "Kore" }]
)

audio.write("speech.pcm")
puts "#{audio.sample_rate} Hz, #{audio.num_channels} channel"
```

The API currently returns base64-encoded linear PCM with format metadata. The 
`FlowSpeech::Audio#bytes` method returns the decoded bytes without changing the encoding.

## Multi-speaker dialogue

```ruby
audio = client.synthesize(
  text: "Host: Welcome to the show.\nGuest: Thanks for having me.",
  speakers: [
    { speaker: "Host", voice_name: "Charon" },
    { speaker: "Guest", voice_name: "Kore" }
  ]
)
```

## Check quota

```ruby
quota = client.quota
puts "#{quota.fetch("remaining")} characters remaining"
```

## Error handling

```ruby
begin
  client.synthesize(text: "Hello")
rescue FlowSpeech::APIError => error
  warn "#{error.status}: #{error.message}"
  warn "Retry after #{error.retry_after}s" if error.retryable
end
```

## Development

Run the tests without real credentials or network requests:

```bash
ruby -Ilib test/client_test.rb
```

Build the gem locally:

```bash
gem build flowspeech.gemspec
```

## Security

- Never commit API keys.
- Load `FLOWSPEECH_API_KEY` from the environment or a secret manager.
- The client sends the key only in the `Authorization: Bearer` header.
- Tests use an injected fake transport and contain no credentials.

## License

MIT

