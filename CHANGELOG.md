# Changelog

## 0.2.1 - 2026-10-27

- Suppress raw download transport causes so full_message does not reveal private result URLs; preserve recovery IDs.
- Use generic API error messages and filter reflected key/URL values from error codes and traces, including terminal job errors.
- Do not retry a known permanent HTTP error or redirect when its body is interrupted; audio downloads remain single-attempt operations.
- Preserve received HTTP status, Retry-After and trace metadata when a response body is interrupted; retries keep the same UUID and bytes. Previously published 0.2.0 artifacts remain unchanged.

## 0.2.0

- Validate RIFF/WAVE chunk sizes, 24000 Hz mono 16-bit PCM format and complete aligned nonempty audio data; preserve valid files byte-for-byte and reject malformed downloads without resubmitting.

- Replaced retired synchronous endpoints with public API v1 jobs and separate WAV downloads.
- Preserved single-voice synthesis and locally encoded base64; added explicit dialogue segments, recovery, cancellation, voices and full quota metadata.
- Added stable UUID retries, total deadlines, Retry-After handling, terminal/deleted-result validation, response limits and credential-free downloads with no redirects.
- Rejects unsupported legacy options and labelled script mappings. Requires a paid API subscription/key; retains Ruby 2.6 support.

## 0.1.1

- Previous published synchronous client release, superseded by 0.2.0.
