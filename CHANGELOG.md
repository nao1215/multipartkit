# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.0] - 2026-05-09

### Documentation

- README gains a `## Security notes` section with two callouts:
  (a) `part.filename` returns the client-supplied filename
  unsanitised, and naive `simplifile.write("./uploads/" <> filename,
  bytes)` is exposed to path traversal — the section shows a
  basename-style sanitiser and the strongly-preferred content-hash
  alternative; (b) the form-builder strip behaviour and the
  strict-variant escape hatch (cross-references the
  `add_field_strict` / `add_file_strict` entry below). Comparable
  Node / Go libraries (busboy, gorilla/mux multipart) explicitly
  warn; this brings multipartkit in line. (#42)

### Added

- **`multipartkit/form`**: `add_field_strict` and `add_file_strict`
  are the typed-error counterparts of the existing
  `add_field` / `add_file`. The non-strict variants silently strip
  CR / LF / NUL bytes from the values that flow into header lines
  (so `add_field("name\n", _)` produces a part with `name=""`,
  and `add_file(_, "fi\nle.png", _, _)` concatenates the two
  halves into the *different valid filename* `"file.png"` — the
  authorisation-relevant identifier change described in #41).
  The strict variants surface the bad input as
  `Error(NameContainsControlBytes(value:))` /
  `Error(FilenameContainsControlBytes(value:))` /
  `Error(ContentTypeContainsControlBytes(value:))` so callers
  passing user-typed or upstream data can render an actionable
  error rather than producing the wrong wire silently. Add the
  matching `FormError` type (re-exported from the top-level
  `multipartkit` module). The existing non-strict variants keep
  their void return for backward compatibility, with doc-comments
  updated to point at the strict counterparts. (#40, #41)
- Property-based and metamorphic tests using
  [metamon](https://github.com/nao1215/metamon) covering
  `multipartkit.encode_form` ↔ `multipartkit.parse` and the
  `multipartkit/form` builder. Lives in
  `test/multipartkit_metamon_test.gleam`. Highlights: the
  encode-then-parse round-trip preserves field count, name, and
  value for safe (alphanumeric) inputs; `query.field` and
  `query.fields` agree on the registration order for duplicate
  names; file parts round-trip name / filename / content-type /
  body byte-exact; `add_field` body equals `<<value:utf8>>`;
  `add_file` preserves byte-exact body of arbitrary `BitArray`;
  CR / LF / NUL injection in `name` / `filename` is silently
  stripped (pinning the existing #28-fix sanitization until #40 /
  #41 switch this to a typed error); empty form parses to the
  empty part list. The round-trip generators use `no_edges` so the
  CR / LF strip behaviour is exercised explicitly rather than as a
  silent edge.

## [0.10.0] - 2026-05-08

### Fixed
- **`part.new/5`** now synthesises the `Content-Disposition` and / or
  `Content-Type` headers on the way through the constructor when the
  caller passes `name` / `filename` / `content_type` cache values without
  the matching header entry in `headers`. Previously those parameters
  were stored as memos only — the encoded wire image omitted the
  corresponding header lines, so a `multipartkit.encode |> parse`
  round-trip dropped `name`, `filename`, and `content_type` to `None`.
  The synthesised `Content-Disposition` value uses the same shape that
  `multipartkit/form.add_field` and `add_file` emit (legacy
  `filename="..."` for ASCII filenames, RFC 5987 `filename*=UTF-8''...`
  with an ASCII fallback for non-ASCII filenames). When the relevant
  header is already present in `headers`, the caller's explicit value
  wins — synthesis does not duplicate or replace it. The existing CRLF
  / NUL guard now also applies to `name`, `filename`, and `content_type`
  because they may be promoted to header values; offending inputs
  surface as `Error(InvalidHeaderValue("Content-Disposition" |
  "Content-Type", value))` rather than silently emitting an off-spec
  wire image. (#37)

## [0.9.0] - 2026-05-08

### Security
- **`encoder.encode/2` and `multipartkit.encode/2` now validate the
  caller-supplied boundary** against RFC 2046 §5.1.1 before producing
  bytes. Previously the encoder accepted any `String` and emitted the
  raw bytes verbatim, so a caller who built the boundary from data
  (request id, user-agent fragment, etc.) could produce a wire image
  whose framing bytes contain `CR` / `LF` / `--BOUNDARY` collisions and
  splice forged headers ahead of the first real part. This release adds
  the encode-side companion to the existing `Part.new/5` header guard
  (#28): the validator that already lived in `multipartkit/header` (and
  that the *parse* path consulted) is now wired into the *encode* path
  too — one source of truth, one rejection set.
  `encoder.encode_stream/2` surfaces the same diagnostic on the first
  emission of the returned yielder. (#34)

### Changed
- **Breaking (`encoder.encode/2`, `multipartkit.encode/2`)**: now
  return `Result(BitArray, MultipartError)` instead of `BitArray`.
  Callers updating: `let assert Ok(body) = multipartkit.encode(b, ps)`
  for the legacy signature when the boundary is hard-coded. Boundaries
  generated by `encode_form` / `generate_boundary` always pass the
  validator, so internal use sites are unaffected. (#34)

### Added
- **`multipartkit/header.validate_boundary/1`** is now part of the
  public API. Useful when callers want to validate a boundary
  independently of the encode call (e.g. to surface the diagnostic
  earlier in a request pipeline). The same predicate gates both the
  parse-side `header.boundary/1` and the encode-side `encoder.encode/2`,
  so "would parse round-trip this?" and "will encode emit this?" agree.
  (#34)

## [0.8.0] - 2026-05-07

### Added
- **`part.equal_on_wire/2`** and **`part.list_equal_on_wire/2`** —
  structural equality predicates that compare two `Part` values (or
  two `Part` lists) by their wire-level content. The comparison
  preserves header order and uses case-sensitive header-name
  matching (mirroring RFC 7578 §4.2), and intentionally ignores the
  convenience cache fields (`name`, `filename`, `content_type`)
  because those are derived from the headers and may differ between
  a `Part.new/5`-constructed value and a parsed `Part` even when
  the wire image is byte-identical. Previously, every consumer that
  wanted "do these encode to the same bytes?" had to project to
  `(all_headers, body)` themselves; multipartkit now owns that
  equality so the right RFC interpretation lives in one place and
  consumers can keep the projection out of property-test code. (#27)

### Fixed
- **`Part.new/5` now strips RFC 7230 §3.2.4 OWS** (space and
  horizontal tab) from the surrounding edges of every header value
  at construction time, mirroring what the parser does on the wire
  side. Previously, `Part.new(headers: [#("X-Foo", " spaced")], ...)`
  stored the value verbatim, but `encode → parse` produced
  `Some("spaced")` — the in-memory `Part` was no longer equal to
  itself across a wire round-trip. This was a property-test
  reliability problem (`forall_round_trip` would always fail) and
  forced consumers to wrap `Part` equality with a normalising
  projection. Whitespace *inside* a value (between tokens) is part
  of the data and is preserved verbatim. The constructor uses an
  RFC-7230-specific OWS predicate (only `0x20` and `0x09`) rather
  than `string.trim`, which would also strip Unicode whitespace.
  This is a behaviour change for `Part` values that explicitly
  carried surrounding whitespace; the wire image already lost that
  data — the in-memory model now matches. (#29)

### Security
- **multipart CRLF / NUL injection in `Part.new/5`** —
  `multipartkit/part.new/5` now validates header names and values
  before constructing a `Part` and returns
  `Result(Part, MultipartError)` instead of `Part`. Header values
  containing `\r`, `\n`, or NUL are rejected with
  `Error(InvalidHeaderValue(name, value))`; header names containing
  any of those bytes or a `:` are rejected with
  `Error(InvalidHeaderName(name))`. Previously, an attacker who
  controlled a header value could smuggle additional header lines
  into the encoded wire image — the multipart variant of CRLF
  response splitting (RFC 9110 §5.5 disallows these bytes in
  `field-value`). Two new variants in `MultipartError`,
  `InvalidHeaderName` and `InvalidHeaderValue`, surface the rejection.
  Internal callers (`form.add_field`, `form.add_file*`,
  `parser.parse`) already sanitise or pre-validate their input and
  use a new `@internal` `part.unchecked_new` helper that skips the
  check; no behaviour change for callers of the `form` builder. (#28)

### Breaking change (security fix)
- `Part.new/5` signature is now
  `Result(Part, MultipartError)` instead of `Part`. Existing
  call sites must `use part <- result.try(part.new(...))` (or
  `let assert Ok(part) = part.new(...)` when input is statically
  safe). The bug closed by this change is severe enough to justify
  a major bump on its own.

## [0.7.0] - 2026-05-06

### Fixed
- `multipartkit.parse/2` (and the streaming parser, which shares the
  same delimiter scanner) now accepts RFC 2046 §5.1.1
  `transport-padding` — `*LWSP-char` (spaces or tabs) between the
  boundary token and the trailing CRLF/LF (or `--` for the closing
  delimiter). Previously the scanner only matched `--<boundary>\r\n`
  exactly, so a body whose opening delimiter was `--BND  \r\n`
  parsed as `Ok([])` (empty multipart) and silently swallowed every
  part. Cross-vendor wires routinely arrive with non-zero padding
  (some HTTP intermediaries inject it for line-length normalisation),
  so the scanner now follows the RFC. The same change covers the
  inter-part delimiter and the close-delimiter
  (`--<boundary>--<padding>\r\n`). (#24)

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
