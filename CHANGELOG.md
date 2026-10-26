# Changelog

## 0.2.0

- Validate RIFF/WAVE chunk sizes, 24000 Hz mono 16-bit PCM format and complete aligned nonempty audio data; preserve valid files byte-for-byte and reject malformed downloads without resubmitting.

- Replaced retired synchronous endpoints with public API v1 jobs and separate WAV downloads.
- Preserved single-voice synthesis and locally encoded base64; added explicit dialogue segments, recovery, cancellation, voices and full quota metadata.
- Added stable UUID retries, total deadlines, Retry-After handling, terminal/deleted-result validation, response limits and credential-free downloads with no redirects.
- Rejects unsupported legacy options and labelled script mappings. Requires a paid API subscription/key; retains Ruby 2.6 support.

## 0.1.1

- Previous published synchronous client release, superseded by 0.2.0.
