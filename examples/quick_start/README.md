# quick_start

Build a `multipart/form-data` body, encode it, and parse it back.

```sh
cd examples/quick_start
gleam run
```

Expected output (boundary value is random per run):

```
Content-Type: multipart/form-data; boundary=----multipartkit-...
title=hello
avatar filename=cat.png
```
