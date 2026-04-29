# streaming_parse

Use `parse_stream` to feed multipart input chunk-by-chunk through a
`Yielder(BitArray)`, and observe `max_body_bytes` being enforced
incrementally.

```sh
cd examples/streaming_parse
gleam run
```

Expected output (truncated):

```
# Happy path
- hello — text: world
- avatar — binary, 4 bytes

# Oversized stream — rejected before all chunks are pulled
rejected after pulling chunk 1: BodyTooLarge(30)
```

## What "streaming" means in v0.1.0

- The **input** chunks yielder is pulled lazily — `parse_stream` does
  not buffer the entire request body up front, and `max_body_bytes` is
  enforced incrementally as each chunk arrives.
- Each `StreamPart.body` is **buffered into a single chunk** before the
  part is yielded; per-part memory is bounded by `max_part_bytes`. True
  chunk-by-chunk body streaming is on the roadmap but is not part of
  v0.1.0.
