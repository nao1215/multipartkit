# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.0] - 2026-05-05

### Documentation

- **readme**: extend the Quick start snippet with `part.body(avatar)` and
  print the byte size of the parsed file part. New users no longer have
  to grep `multipartkit/part` to find the BitArray accessor. The
  `examples/quick_start` source is updated in lockstep so the
  README/example byte-equality check still passes. (#21)

## [0.5.0] - 2026-05-04

### Documentation

- **readme**: `gleam add multipartkit` is the only step on the main
  install path now. The extra `gleam add gleam_yielder` line moved into
  the streaming-specific section, where it is actually needed. (#18)

### Changed

- **query**: `query.field` now wraps `query.required_field` so the
  find-the-text-field-and-decode-utf8 logic only exists once. The
  result is funneled through `option.from_result` to satisfy glinter's
  `thrown_away_error` rule. Public behavior unchanged. (#18)

## [0.4.0] - 2026-04-30

### Added

- **Golden wire fixtures for the encoder, parser, and streaming
  parser** in `test/multipartkit/golden_fixtures_test.gleam`. Each
  fixture pins the exact bytes of a representative multipart body
  and asserts the property called out in the issue:
  - canonical form-data with a text field plus a binary file part
  - non-ASCII filenames using RFC 5987 `filename*` (parser prefers
    `*=` over the legacy fallback per RFC 5987 §3.2.2)
  - the streaming parser is invariant under chunk-split shape
    (single chunk, byte-by-byte, split inside a header block, split
    inside a part body)
  - malformed inputs whose error variant (`UnexpectedEndOfInput`,
    `InvalidContentDisposition`) is part of the contract
  Closes a gap where wire-formatting shifts (header order, quoting
  style, CRLF placement, `filename*` precedence) could land without
  a single per-property assertion noticing. (#11)

### Changed

- **Streaming parser stabilises with chunked body emission and
  incremental `max_part_bytes`**. `StreamPart.body` now surfaces large
  parts as a sequence of fixed-size `Ok(BitArray)` items (up to ~64 KiB
  each) instead of a single buffered chunk, so consumers can fold over
  a multi-megabyte part without first materialising the entire body as
  one application-level `BitArray` (small parts still fit in a single
  chunk, and `stream.drain_body` continues to fold the yielder back
  into one buffer). `parse_stream` and `parse_stream_with_limits` also
  enforce `max_part_bytes` incrementally during body parsing — an
  oversized single part is now rejected at the chunk that crosses the
  per-part limit, not after the whole part has been buffered.
  `stream.from_part` adapts buffered parts into the same chunked
  yielder shape so that mixed pipelines see a uniform body surface.
  README and the `streaming_parse` example are updated and the
  "single buffered chunk" caveat has been removed. (#7)

- **`Limits`, `Part`, `StreamPart`, and `ContentDisposition` are now
  `pub opaque type` (BREAKING)**. Direct constructor calls
  (`Limits(...)`, `Part(...)`, `StreamPart(...)`,
  `ContentDisposition(...)`) and field-access expressions
  (`limits.max_body_bytes`, `the_part.body`, `parsed.disposition`,
  etc.) no longer compile from outside the defining module. The
  representation can now evolve without breaking external pattern
  matches. Migration paths:

  - `Limits` — construct with `limit.new(max_body_bytes:,
    max_part_bytes:, max_parts:, max_header_bytes:)` (returns
    `Result(Limits, LimitConfigError)`) or `limit.default_limits()`.
    Read fields via the `limit.max_body_bytes/1`,
    `limit.max_part_bytes/1`, `limit.max_parts/1`, and
    `limit.max_header_bytes/1` accessors that already shipped in
    v0.3.0.
  - `Part` — construct with `part.new(headers:, name:, filename:,
    content_type:, body:)`. Read fields via `part.all_headers/1`,
    `part.name/1`, `part.filename/1`, `part.content_type/1`, and
    `part.body/1`. The existing `part.header/2` and `part.headers/2`
    case-insensitive header lookups are unchanged.
  - `StreamPart` — receive from `stream.parse_stream` /
    `stream.from_part`; inspect via `stream.all_headers/1`,
    `stream.name/1`, `stream.filename/1`, `stream.content_type/1`,
    and `stream.body/1`.
  - `ContentDisposition` — receive from
    `content_disposition.parse/1`; inspect via
    `content_disposition.disposition/1`,
    `content_disposition.name/1`, `content_disposition.filename/1`,
    and `content_disposition.params/1`.

  README and examples are updated to use the accessors. (#8)

## [0.3.0] - 2026-04-30

### Added

- **limit**: validated `Limits` builder `limit.new(...)` returns
  `Result(Limits, LimitConfigError)` and rejects non-positive values
  through the `NonPositiveLimit(field:, given:)` variant. Field
  accessor functions (`max_body_bytes`, `max_part_bytes`, `max_parts`,
  `max_header_bytes`) provide a stable inspection surface ahead of
  the `Limits` type being closed. The top-level facade re-exports
  the type and builder as `multipartkit.LimitConfigError` and
  `multipartkit.new_limits`. Direct `Limits(...)` construction stays
  available so this is non-breaking, but the runnable examples now
  use the validated builder. (#10)

## [0.2.0] - 2026-04-29

### Fixed

- **`form.add_file` / `form.add_file_auto`** now emit the RFC 5987 §3.2.1
  `filename*=UTF-8''<percent-encoded>` form (alongside a sanitised legacy
  `filename="<ascii-fallback>"`) when the filename contains bytes outside
  the printable US-ASCII range. Previously, non-ASCII filenames were
  emitted verbatim inside the legacy `filename="..."`, producing a
  `Content-Disposition` value that violates RFC 7230 §3.2.4 and gets
  mangled or rejected by strict HTTP intermediaries (cowboy, nginx, Go
  `net/http`, browsers proxying uploads, …). ASCII-only filenames
  continue to emit the legacy form unchanged. The non-ASCII fallback
  legacy form replaces each non-ASCII grapheme with `_`. Round-tripping
  through `parser.parse` recovers the original filename via the existing
  RFC 5987 decoder in `content_disposition.parse`. (#4)

## [0.1.0] - 2026-04-29

First public release.

### Added

- Project scaffold: Gleam package metadata, cross-target CI workflows,
  release automation, `just` recipes, mise toolchain management, and
  contributor-facing project documents.
- Full implementation of the v0.1.0 multipart API:
  - `multipartkit/parser` — full-body parser (`parse`,
    `parse_with_limits`)
  - `multipartkit/encoder` — `encode`, `encode_form`, `encode_stream`
  - `multipartkit/stream` — lazy streaming parser
    (`parse_stream`, `parse_stream_with_limits`) with incremental
    `max_body_bytes` enforcement and bounded per-part memory
  - `multipartkit/form` — opaque `Form` builder with `add_field`,
    `add_file`, `add_file_auto`, `add_file_auto_with`,
    `unsafe_add_part`, `parts`
  - `multipartkit/query` — `field`, `required_field`, `fields`, `file`,
    `required_file`, `files`, `names`
  - `multipartkit/validate` — `has_field`, `max_file_size`,
    `allowed_content_types`
  - `multipartkit/content_disposition` — RFC 5987 / RFC 8187
    `filename*` decoding (UTF-8 and ISO-8859-1)
  - `multipartkit/header` — `boundary` extraction with the documented
    error priority
  - `multipartkit/limit` — `Limits` and `default_limits`
  - `multipartkit/infer` — pluggable `Inferer` (default `None`); wire
    `nao1215/mimetype` or another inferer via `add_file_auto_with`
- 136 unit tests passing on both Erlang/BEAM and JavaScript targets.

### Security

- `form.add_field` / `add_file` / `add_file_auto` / `add_file_auto_with`
  silently strip CR, LF, and NUL from the `name`, `filename`, and
  `content_type` parameters to prevent header injection. The cached
  `name` / `filename` / `content_type` on the resulting `Part` reflect
  the sanitized values, so `form.parts` and a parse-after-encode
  round-trip agree. Use `unsafe_add_part` if byte-exact preservation is
  required.

### Documentation

- Four runnable examples under `examples/` — `quick_start`,
  `parse_request`, `streaming_parse`, and `mimetype_inference`. The
  `just examples` recipe builds and runs them all under
  `--warnings-as-errors`; CI runs the same recipe on every push.
- README written as a user-facing front door: badges, install,
  quick-start, examples table, and an explicit streaming caveat for
  v0.1.0. The README quick-start snippet is pinned to the
  `examples/quick_start` source via `scripts/check_readme_snippet.sh`,
  enforced by CI.

[0.1.0]: https://github.com/nao1215/multipartkit/releases/tag/v0.1.0
