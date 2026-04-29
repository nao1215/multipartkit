# mimetype_inference

Wire [`nao1215/mimetype`](https://github.com/nao1215/mimetype) into
multipartkit's pluggable `Inferer` so `add_file_auto_with` can derive
the correct `Content-Type` from either the filename or the leading
bytes.

```sh
cd examples/mimetype_inference
gleam run
```

Expected output:

```
- name=avatar filename=cat.png content_type=image/png
- name=no_extension filename=blob content_type=image/png

After round-trip:
- name=avatar filename=cat.png content_type=image/png
- name=no_extension filename=blob content_type=image/png
```

The first part's content type is inferred from the `.png` extension;
the second part has no extension so the inferer falls through to magic
byte detection. Both inferred types survive a `parse(encode_form(...))`
round-trip.
