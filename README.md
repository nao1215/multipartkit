# multipartkit

[![CI](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/multipartkit/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/multipartkit/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/multipartkit/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/multipartkit)](https://hex.pm/packages/multipartkit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/multipartkit/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/multipartkit)](https://hex.pm/packages/multipartkit)
[![License](https://img.shields.io/github/license/nao1215/multipartkit)](./LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/multipartkit/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/multipartkit)

A Gleam library for parsing, querying, validating, and building
multipart messages on Erlang/BEAM and JavaScript. It targets
`multipart/form-data` first, and also handles `multipart/mixed` and
`multipart/related` per the RFC 2046 §5.1.1 grammar.

It is pure Gleam with no FFI. It has a full-body parser, an opaque
`Form` builder, a streaming parser that enforces `max_body_bytes` per
chunk, a `Content-Disposition` parser that reads RFC 5987 / RFC 8187
`filename*` (UTF-8 and ISO-8859-1), and conservative default limits you
can change at runtime. `multipartkit/infer` guesses a content type from
a filename or magic bytes through
[`nao1215/mimetype`](https://github.com/nao1215/mimetype); the form
builder only uses it when you pass `infer.builtin_inferer()` to
`add_file_auto_with` (see
[`examples/mimetype_inference`](examples/mimetype_inference)).

## Install

```sh
gleam add multipartkit
```

The streaming parser also needs `gleam_yielder`; see
[Streaming](#streaming).

## Quick start

This is [`examples/quick_start`](examples/quick_start), checked against
the README in CI.

```gleam
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import multipartkit
import multipartkit/form
import multipartkit/part
import multipartkit/query

pub fn main() {
  let request_form =
    form.new()
    |> form.add_field("title", "hello")
    |> form.add_file("avatar", "cat.png", "image/png", <<137, 80, 78, 71>>)

  let #(content_type, body) = multipartkit.encode_form(request_form)

  let assert Ok(parts) = multipartkit.parse(body, content_type)
  let assert Ok(title) = query.required_field(parts, "title")
  let assert Ok(avatar) = query.required_file(parts, "avatar")

  io.println("Content-Type: " <> content_type)
  io.println("title=" <> title)
  case part.filename(avatar) {
    Some(filename) -> io.println("avatar filename=" <> filename)
    None -> io.println("avatar has no filename")
  }
  let avatar_bytes = part.body(avatar)
  io.println("avatar size=" <> int.to_string(bit_array.byte_size(avatar_bytes)))
}
```

Output of `gleam run` (the boundary is random on each run):

```text
Content-Type: multipart/form-data; boundary=----multipartkit-y9o53iydy0zm2dxbmbhvbsi9
title=hello
avatar filename=cat.png
avatar size=4
```

The full API is on [HexDocs](https://hexdocs.pm/multipartkit/).

## Examples

Each directory under [`examples/`](examples/) is a standalone Gleam project:

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

## Security notes

### Filenames are user-controlled

`part.filename(part)` returns the bytes the client sent, unsanitised,
including `../`, absolute paths like `/etc/passwd`, Windows UNC paths
like `\\server\share`, and URL-encoded forms like
`..%2f..%2fetc%2fpasswd`. multipartkit leaves the name as sent because
the exact original is sometimes worth keeping, so sanitising it is up
to you. Joining it straight onto a server path allows path traversal:

```gleam
let assert Ok(part) = mquery.required_file(parts, "upload")
let bytes = part.body(part)
let assert Some(filename) = part.filename(part)
simplifile.write("./uploads/" <> filename, bytes)
// ^^^^ attacker-controlled, writes outside ./uploads
```

Sanitise before joining, or better, build the server path from a
content hash so the client's name never reaches the filesystem:

```gleam
import filepath
import gleam/string

let safe = filepath.base_name(filename) |> string.replace("..", "")
simplifile.write(filepath.join("./uploads", safe), bytes)
```

```gleam
// Even better: use a content-derived id and recover the extension
// from a magic-byte detector instead of the user-supplied filename.
let extension = case mimetype.essence(detected) {
  "image/png" -> "png"
  "image/jpeg" -> "jpg"
  _ -> "bin"
}
let server_path = filepath.join("./uploads", sha256_of(bytes) <> "." <> extension)
```

### Header-breaking bytes in form-builder values

`form.add_field` / `form.add_file` / `form.add_file_auto[_with]`
silently strip CR / LF / NUL bytes from values that end up in header
lines. That blocks CRLF injection but changes the input:
`add_file(_, "fi\nle.png", _, _)` produces a part named `"file.png"`.
For user-typed or upstream data, use `form.add_field_strict` /
`form.add_file_strict`, which return `Result(Form, FormError)` instead.

## Streaming

The streaming parser is opt-in and needs one more package:

```sh
gleam add gleam_yielder
```

`parse_stream` pulls input chunks lazily and rejects an oversized body
or part at the chunk that crosses `max_body_bytes` or `max_part_bytes`,
before the rest is buffered. Each `StreamPart.body` is a single-pass
yielder of chunks up to about 64 KiB, so you can forward a body to a
file or hash without holding it in memory; `stream.drain_body` collects
it when you want it whole. `from_part` turns a buffered `Part` into the
same shape. See [`examples/streaming_parse`](examples/streaming_parse).

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

`mise activate` is not needed in your shell. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

## Testing

| Technique | Bug class caught here |
|---|---|
| Examples and unit tests | [Wrong parts, headers and errors; golden wire bytes](doc/testing.md#examples-and-unit-tests) |
| Generated properties | [Encode / parse round trips that lose fields or bytes](doc/testing.md#generated-properties) |
| Differential testing | [Buffered and streaming parsers disagreeing on chunking, damage or limits](doc/testing.md#differential-testing) |
| Boundary tables | [Off-by-one character classes in `filename*` and quoted-pair](doc/testing.md#boundary-tables) |
| Nightly runs | [Rare inputs the normal run count misses](doc/testing.md#nightly-runs) |
| Mutation testing | [Assertions that miss a changed operator or branch](doc/testing.md#mutation-testing) |

## Verifying releases

Each GitHub Release attaches the Hex package tarball (`multipartkit-<version>.tar`),
`checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and
build provenance (`multipartkit-<version>.intoto.jsonl`). Download the assets, then:

```sh
gh attestation verify multipartkit-<version>.tar --repo nao1215/multipartkit

cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/nao1215/multipartkit/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check checksums.txt
```

## License

[MIT](LICENSE)
