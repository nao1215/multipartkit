# multipartkit

`multipartkit` is a Gleam library for parsing, querying, validating, and
building multipart messages on Erlang and JavaScript targets. The
primary target is `multipart/form-data`; `multipart/mixed` and
`multipart/related` work for parsing per RFC 2046 §5.1.1 grammar.

Highlights:

- Pure Gleam — no FFI; runs on both Erlang/BEAM and JavaScript targets
- Full-body and streaming parser/encoder
- `Form` opaque builder, query helpers (`field` / `file` /
  `required_*`), validation primitives, and configurable limits
- `Content-Disposition` parser including RFC 5987 / RFC 8187
  `filename*` (UTF-8 and ISO-8859-1)

## Development setup

```console
mise trust .mise.toml
mise install
just deps
just ci
```

`just` recipes source `scripts/lib/mise_bootstrap.sh`, so
`mise activate` is not required in the current shell.

## Usage

Build a `multipart/form-data` body and parse it back:

```gleam
import multipartkit
import multipartkit/form
import multipartkit/query

pub fn example() {
  let body =
    form.new()
    |> form.add_field("title", "hello")
    |> form.add_file(
      "avatar",
      "cat.png",
      "image/png",
      <<137, 80, 78, 71>>,
    )

  let #(content_type, encoded) = multipartkit.encode_form(body)
  let assert Ok(parts) = multipartkit.parse(encoded, content_type)

  let assert Ok(_title) = query.required_field(parts, "title")
  let assert Ok(_avatar) = query.required_file(parts, "avatar")
}
```

### Streaming parse

`parse_stream` pulls chunks from a `Yielder(BitArray)` lazily and yields
`StreamPart`s as soon as their headers and body have been buffered.
`max_body_bytes` is enforced incrementally, so an oversized stream is
rejected before it is fully consumed.

```gleam
import gleam/yielder
import multipartkit
import multipartkit/stream

pub fn handle(chunks, content_type) {
  // Errors decidable from `content_type` alone surface in the outer Result.
  let assert Ok(parts) = multipartkit.parse_stream(chunks, content_type)

  yielder.each(parts, fn(item) {
    case item {
      Ok(stream_part) -> {
        let assert Ok(_body) = stream.drain_body(stream_part.body)
        Nil
      }
      // After the first error the iterator is exhausted; subsequent steps
      // return Done.
      Error(_) -> Nil
    }
  })
}
```

### Validation

`multipartkit/validate` exposes small composable predicates that play
well with `dataprep`-style validation pipelines:

```gleam
import multipartkit/query
import multipartkit/validate

pub fn require_avatar(parts) {
  let assert Ok(avatar) = query.required_file(parts, "avatar")
  let assert Ok(avatar) = validate.max_file_size(avatar, 5_000_000)
  validate.allowed_content_types(avatar, ["image/png", "image/jpeg"])
}
```

### Inferring file content types

`form.add_file_auto` always falls through to `application/octet-stream`
because the default inferer returns `None`. Wire
[`nao1215/mimetype`](https://github.com/nao1215/mimetype) (or any
other inferer) via `add_file_auto_with` to opt into inference:

```gleam
import gleam/option.{None, Some}
import mimetype
import multipartkit/form
import multipartkit/infer.{Inferer}

let mimetype_inferer =
  Inferer(
    from_filename: fn(name) {
      case mimetype.filename_to_mime_type_strict(name) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
    },
    from_bytes: fn(bytes) {
      case mimetype.detect_strict(bytes) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
    },
  )

let form_value =
  form.new()
  |> form.add_file_auto_with("upload", "x.png", bytes, mimetype_inferer)
```

The complete API lives across the public submodules:
`multipartkit/parser`, `multipartkit/encoder`, `multipartkit/form`,
`multipartkit/query`, `multipartkit/stream`, `multipartkit/validate`,
`multipartkit/content_disposition`, `multipartkit/header`,
`multipartkit/infer`, and `multipartkit/limit`.
