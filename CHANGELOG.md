# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
