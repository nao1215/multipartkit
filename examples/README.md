# multipartkit examples

Each subdirectory is a self-contained Gleam project that depends on
`multipartkit` via a path dependency. Run any of them with:

```sh
cd examples/<name>
gleam run
```

| Example | What it shows |
|---|---|
| `quick_start` | Build a `multipart/form-data` body, encode it, parse it back. The shortest "first success" path. |
| `parse_request` | Parse a synthetic incoming HTTP request body, then validate it with `query.required_*` and the helpers in `multipartkit/validate`. |
| `streaming_parse` | Feed input through `parse_stream` chunk-by-chunk and observe `max_body_bytes` being enforced incrementally. Includes a clear note about what "streaming" does and does not mean in v0.1.0. |
| `mimetype_inference` | Wire [`nao1215/mimetype`](https://github.com/nao1215/mimetype) into the pluggable `Inferer` so `add_file_auto_with` can derive the right `Content-Type`. |

The `justfile` in the repo root has `example-*` recipes that build and
run each example with `--warnings-as-errors`, and a single `examples`
recipe that runs them all. CI runs `just examples` on every push.
