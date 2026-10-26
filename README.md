# FlowSpeech Ruby

Ruby 2.6+ client for the [FlowSpeech public API v1](https://flowspeech.io/docs/public-api),
using only the standard library at runtime. Requires an active paid Basic, Pro
or Scale subscription (not a trial) and a key from [API settings](https://flowspeech.io/settings/apikeys).

```ruby
gem "flowspeech", "~> 0.2.0"
```

Set `FLOWSPEECH_API_KEY` through your environment or secret manager. Use this gem
on your server, never in a public client. Generation consumes account credits.

## Generate WAV Audio

```ruby
require "flowspeech"

client = FlowSpeech::Client.new
request_id = SecureRandom.uuid
# Persist this ID before submitting. Reuse it only with unchanged input.
audio = client.synthesize(
  text: "Welcome to FlowSpeech.",
  speakers: [{ voice_name: "Kore" }],
  request_id: request_id
)
audio.write("speech.wav")
puts "#{audio.sample_rate} Hz, #{audio.num_channels} channel"
```

`synthesize` submits a job, polls until `success`, and downloads WAV audio
(24000 Hz, mono, 16 bit). `audio_base64` is encoded **locally** for compatibility;
v1 does not return base64 or raw PCM. `Audio` exposes `job_id`, `request_id`,
`usage`, `bytes`, and `write`. `audio.quota` is no longer populated.

## Explicit Dialogue

```ruby
audio = client.synthesize(segments: [
  { speaker: "Alice", text: "Welcome!", voice_name: "Kore" },
  { speaker: "Bob", text: "Thank you.", voice_name: "Puck" }
])
```

Use `segments` without `text` or `speakers`. Legacy labelled dialogue, multiple
speaker assignments, and `original_text` are rejected. Segment hashes accept
`voice_name` or `voiceName`, not both. Unknown fields/options (including model,
source, speed and output format) are rejected, not silently ignored.

## Jobs And Recovery

```ruby
job = client.create_job(text: "Hello", request_id: request_id)
job = client.wait_job(job)
File.binwrite("speech.wav", client.download(job))
```

- `get_job(job_id)` returns a direct v1 job hash.
- `find_job(request_id)` recovers an interrupted submission by UUID.
- `cancel_job(job_id)` explicitly cancels server work.
- `wait_job(job)` polls queued/running/merging/settling; failed/cancelled jobs raise `FlowSpeech::JobError` with `status` and `error_code`.
- `download(job)` downloads only; retrying it never submits new work.
- `voices` returns the top-level voice list.
- `quota` retains the convenience credit hash; `quota_details` preserves the full `quota`, `entitlement`, `subscription`, and `limits` response. Use `quota["available"]` for new work.

The server returns `subscription`; `entitlement` is also accepted for
compatibility. Neither field is discarded. HTTP 200 is not proof that generation succeeded. A deleted
result has `status: "success"`, `result: nil`, and `resultDeleted: true`;
`wait_job`/`download` raise `JobError` with `result_deleted == true`.

`FlowSpeech::Error` carries `request_id`/`job_id` when known. `APIError` adds
`status`, `error_code` (also `code`, now a string), `retryable`, `retry_after`, and
`trace_id`. `DeadlineError` means the configured total deadline was reached or
the required next wait would exceed it. Local interruption does not cancel work.

Recover using the same UUID and input after a lost create response. Do not
create another recording just because its download failed. Generate a new UUID
only for intentionally new work.

## Configuration And Security

Constructor options: `api_key`, `base_url`, `open_timeout` (10 seconds),
`read_timeout` (30), `timeout` (600 total), `poll_interval` (5 minimum),
`max_retries` (2, allowed 0..10), and `max_download_bytes` (64 MiB).
All submit/poll/download work shares one total deadline in `synthesize`.
Network errors, HTTP 429 and retryable 5xx responses get bounded retries with
the same UUID and body. Longer numeric and HTTP-date `Retry-After` is honored.
API responses are bounded to 1 MiB; audio is streamed with the byte limit.

Downloads validate the complete RIFF/WAVE container, PCM format (24000 Hz,
mono, 16 bit), byte rate/block alignment, and nonempty complete sample data.
Truncated, malformed or mismatched audio is rejected even on HTTP 200. Bounded,
word-aligned unknown chunks are skipped; valid files are returned unchanged.

API and audio transports are separate. No Bearer token, cookies or idempotency
key is sent to storage. Redirects are refused for both API and audio requests.
URLs must be HTTPS without credentials/fragments; HTTP loopback is allowed for
tests. Optional `transport`, `download_transport` and `sleeper` are trusted test
hooks; injected transports must not add credentials or follow redirects.
Audio URLs are public link-access URLs, not private authentication tokens.

## Development

```sh
ruby -Ilib test/client_test.rb
gem build flowspeech.gemspec
```

Tests use fake HTTP without keys or generation credits. See [CHANGELOG.md](CHANGELOG.md).
License: MIT.
