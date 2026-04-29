# multipartkit

[![Hex](https://img.shields.io/hexpm/v/multipartkit)](https://hex.pm/packages/multipartkit)
[![Hex Downloads](https://img.shields.io/hexpm/dt/multipartkit)](https://hex.pm/packages/multipartkit)
[![CI](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml)

A Gleam library for parsing, querying, validating, and building
multipart messages on Erlang/BEAM and JavaScript targets. Primary
target: `multipart/form-data`. Secondary: `multipart/mixed` and
`multipart/related` per RFC 2046 §5.1.1 grammar.

- Pure Gleam — no FFI; runs identically on Erlang/BEAM and JavaScript.
- Full-body parser, opaque `Form` builder, and incremental streaming
  parser with safe per-chunk `max_body_bytes` enforcement.
- `Content-Disposition` parser including RFC 5987 / RFC 8187
  `filename*` (UTF-8 and ISO-8859-1).
- Pluggable content-type inference — wire
  [`nao1215/mimetype`](https://github.com/nao1215/mimetype) (or any
  other inferer) without changing this library.
- Conservative default limits, runtime-tunable.

## Install

```sh
gleam add multipartkit
```

For the streaming API you also need
[`gleam_yielder`](https://hex.pm/packages/gleam_yielder):

```sh
gleam add gleam_yielder
```

## Quick start

```gleam
import gleam/option.{Some}
import gleeunit/should
import multipartkit
import multipartkit/form
import multipartkit/query

pub fn round_trip_test() {
  let request_form =
    form.new()
    |> form.add_field("title", "hello")
    |> form.add_file("avatar", "cat.png", "image/png", <<137, 80, 78, 71>>)

  let #(content_type, body) = multipartkit.encode_form(request_form)
  let assert Ok(parts) = multipartkit.parse(body, content_type)

  query.required_field(parts, "title")
  |> should.equal(Ok("hello"))

  let assert Ok(avatar) = query.required_file(parts, "avatar")
  avatar.filename |> should.equal(Some("cat.png"))
}
```

## Examples

The [`examples/`](examples/) directory has four self-contained Gleam
projects you can clone, run, and modify:

| Example | Use case |
|---|---|
| [`quick_start`](examples/quick_start) | Encode a `Form`, parse it back, pull a field and a file. |
| [`parse_request`](examples/parse_request) | Parse an incoming HTTP request body, with strict `Limits` and `validate.allowed_content_types`. |
| [`streaming_parse`](examples/streaming_parse) | Feed input through `parse_stream` chunk-by-chunk and observe `max_body_bytes` being enforced incrementally. |
| [`mimetype_inference`](examples/mimetype_inference) | Wire `nao1215/mimetype` into `add_file_auto_with` to infer `Content-Type`. |

```sh
cd examples/<name>
gleam run
```

Run them all from the repo root with `just examples`.

## Streaming caveat (v0.1.0)

`parse_stream` pulls input chunks lazily and enforces `max_body_bytes`
incrementally, so an oversized stream is rejected at the chunk that
crosses the limit, not after the whole body is buffered. **However**,
each `StreamPart.body` is materialised as a single buffered chunk
before the part is yielded; per-part memory is bounded by
`max_part_bytes` rather than by an arbitrary chunk size. True
chunk-by-chunk body streaming is on the roadmap but is not part of
v0.1.0.

## Public modules

`multipartkit` (facade), `multipartkit/parser`, `multipartkit/encoder`,
`multipartkit/form`, `multipartkit/query`, `multipartkit/stream`,
`multipartkit/validate`, `multipartkit/content_disposition`,
`multipartkit/header`, `multipartkit/infer`, `multipartkit/limit`,
`multipartkit/error`, `multipartkit/part`.

## Contributing / development

The repo uses [`mise`](https://mise.jdx.dev/) for toolchain pinning and
[`just`](https://github.com/casey/just) for task running:

```sh
mise trust .mise.toml
mise install
just deps
just ci
```

`just` recipes source `scripts/lib/mise_bootstrap.sh` so `mise activate`
is not required in the current shell. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the full workflow.

## License

Released under the [MIT License](LICENSE) — see the file for details.
