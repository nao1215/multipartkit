# multipartkit examples

Each subdirectory is a self-contained Gleam project that depends on
`multipartkit` via a path dependency. Run any of them with:

```sh
cd examples/<name>
gleam run
```

| Example | What it shows |
|---|---|
| `quick_start` | Build a `multipart/form-data` body, encode it and parse it back. |
| `parse_request` | Parse a request body with tighter limits and check the fields, the file and its content type. |
| `streaming_parse` | Feed a body to `stream.parse` a chunk at a time and see `max_body_bytes` stop it at the chunk that crosses the limit. |
| `mimetype_inference` | Pick each file's `Content-Type` with `infer_content_type`, from the file name or the first bytes. |

The `justfile` in the repo root has `example-*` recipes that build and
run each example with `--warnings-as-errors`, and a single `examples`
recipe that runs them all. CI runs `just examples` on every push.
