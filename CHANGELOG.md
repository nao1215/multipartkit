# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- 133 unit tests passing on both Erlang/BEAM and JavaScript targets.

### Security

- `form.add_field` / `add_file` / `add_file_auto` / `add_file_auto_with`
  silently strip CR, LF, and NUL from the `name` and `filename`
  parameters to prevent header injection. Use `unsafe_add_part` to
  bypass.
