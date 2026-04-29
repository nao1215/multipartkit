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

The complete API lives across the public submodules:
`multipartkit/parser`, `multipartkit/encoder`, `multipartkit/form`,
`multipartkit/query`, `multipartkit/stream`, `multipartkit/validate`,
`multipartkit/content_disposition`, `multipartkit/header`, and
`multipartkit/limit`.
