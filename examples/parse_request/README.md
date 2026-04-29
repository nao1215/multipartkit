# parse_request

Parse a synthetic HTTP `multipart/form-data` request and surface the
fields a server would care about (two text fields plus an image file)
through the public `query` and `validate` helpers.

```sh
cd examples/parse_request
gleam run
```

Expected output:

```
title: hello world
notes: hand-rolled
avatar: cat.png (8 bytes)
```

The `parse_upload` function in `src/multipartkit_parse_request.gleam`
shows the pattern: tighten `Limits`, run `multipartkit.parse_with_limits`,
pull required fields with `query.required_*`, and reject unwanted
files via `validate.max_file_size` and `validate.allowed_content_types`.
