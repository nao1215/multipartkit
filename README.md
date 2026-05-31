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
- Built-in content-type inference — `multipartkit/infer.content_type_from_filename`
  and `content_type_from_bytes` resolve well-known extensions and
  magic-byte signatures (`"a.png"` -> `Some("image/png")`, a PNG header
  -> `Some("image/png")`) by delegating to
  [`nao1215/mimetype`](https://github.com/nao1215/mimetype), returning
  `None` for unknown input. Inference into the form builder stays
  opt-in: `add_file_auto` uses the no-op `default_inferer` (so it never
  changes a content type implicitly), while
  `add_file_auto_with(form, ..., infer.builtin_inferer())` opts into the
  built-in inference, and a custom `Inferer` lets you wire any other
  library (see
  [`examples/mimetype_inference`](examples/mimetype_inference)).
- Conservative default limits, runtime-tunable.

## Install

```sh
gleam add multipartkit
```

That is all the non-streaming API needs. The streaming parser pulls in
one extra package; see [Streaming semantics](#streaming-semantics) for
the install step and the wiring.

## Quick start

The snippet below is the source of `examples/quick_start` verbatim;
copy it into `src/main.gleam`, run `gleam add multipartkit`, then
`gleam run`.

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

## Security notes

### Filenames are user-controlled

`part.filename(part)` returns the byte sequence the client sent,
**unsanitised** — including path-traversal sequences (`../`,
absolute paths like `/etc/passwd`, Windows UNC like `\\server\share`,
URL-encoded variants like `..%2f..%2fetc%2fpasswd`). Sanitising the
filename is the consumer's responsibility; multipartkit deliberately
does not mutate it because the byte-exact original is sometimes the
right value to keep (e.g. when the client supplies a content-derived
identifier).

A naive consumer that joins the filename to a server-side path is
exposed to path traversal:

```gleam
let assert Ok(part) = mquery.required_file(parts, "upload")
let bytes = part.body(part)
let assert Some(filename) = part.filename(part)
simplifile.write("./uploads/" <> filename, bytes)
// ^^^^ attacker-controlled, writes outside ./uploads
```

Sanitise before joining, or — strongly preferred — derive the
server-side path from a content hash so the user-supplied name is
never on the filesystem:

```gleam
import filepath
import gleam/string

let safe = filepath.base_name(filename) |> string.replace("..", "")
simplifile.write(filepath.join("./uploads", safe), bytes)
```

```gleam
// Even better: use a content-derived id and recover the extension
// from a magic-byte detector instead of the user-supplied filename.
let extension = case mimetype.essence_of(detected) {
  "image/png" -> "png"
  "image/jpeg" -> "jpg"
  _ -> "bin"
}
let server_path = filepath.join("./uploads", sha256_of(bytes) <> "." <> extension)
```

### Header-breaking bytes in form-builder values

`form.add_field` / `form.add_file` / `form.add_file_auto[_with]`
silently strip CR / LF / NUL bytes from values that flow into header
lines. The strip seals the CRLF-injection vector but loses the
caller's input — `add_file(_, "fi\nle.png", _, _)` produces a part
with filename `"file.png"`, a *different valid filename*. For
callers passing user-typed or upstream data, prefer
`form.add_field_strict` / `form.add_file_strict`, which return
`Result(Form, FormError)` and surface the bad input as a typed
error instead of coercing it.

## Streaming semantics

The streaming parser is opt-in. Add it to your project only when you
need chunk-at-a-time parsing — the normal full-body API in the Quick
start above does not depend on it.

```sh
gleam add gleam_yielder
```

`parse_stream` pulls input chunks lazily and enforces `max_body_bytes`
and `max_part_bytes` incrementally, so an oversized stream — or an
oversized individual part — is rejected at the chunk that crosses the
limit, rather than after the whole body has been buffered.

Each `StreamPart.body` is a single-pass yielder that emits the part
body in fixed-size chunks of up to ~64 KiB (a smaller body fits in a
single chunk). Consumers can fold over the body chunk-by-chunk —
forwarding to a file, hash, or downstream stream — without ever
materialising the entire body as a single application-level
`BitArray`. Use `stream.drain_body` when you do want the full body in
memory.

Inside the parser, per-part working memory remains bounded by
`max_part_bytes`. `from_part` adapts a buffered `Part` into the same
chunked-yielder shape so that mixed pipelines see a uniform body
surface.

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
