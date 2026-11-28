# multipartkit

[![CI](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/ci.yml)
![Coverage](https://raw.githubusercontent.com/nao1215/octocovs-central-repo/main/badges/nao1215/multipartkit/coverage.svg)
[![Gitleaks](https://github.com/nao1215/multipartkit/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/multipartkit/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/multipartkit/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/multipartkit/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/multipartkit)](https://hex.pm/packages/multipartkit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/multipartkit/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/multipartkit)](https://hex.pm/packages/multipartkit)
[![License](https://img.shields.io/github/license/nao1215/multipartkit)](https://github.com/nao1215/multipartkit/blob/main/LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/multipartkit/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/multipartkit)

Parse and build multipart bodies, such as `multipart/form-data` file uploads, in Gleam on Erlang and JavaScript.

`parse` turns a request body and its `Content-Type` into parts that `field` and `file` look up by name, and `encode_form` writes the parts that `new_field` and `new_file` build. Parsing stops at limits on body size, part size, part count and header size. `multipartkit/stream` reads a body a chunk at a time when it is too large to hold in memory. The package is pure Gleam and needs `gleam_yielder` and [`mimetype`](https://hex.pm/packages/mimetype) besides the standard library.

```sh
gleam add multipartkit@0
```

## Usage

This is [`examples/quick_start`](https://github.com/nao1215/multipartkit/tree/main/examples/quick_start), which CI runs.

```gleam
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option
import multipartkit

pub fn main() {
  let assert Ok(title) = multipartkit.new_field(name: "title", value: "hello")
  let assert Ok(avatar) =
    multipartkit.new_file(
      name: "avatar",
      filename: "cat.png",
      content_type: "image/png",
      body: <<137, 80, 78, 71>>,
    )
  let #(content_type, body) = multipartkit.encode_form([title, avatar])

  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  let assert Ok(title) = multipartkit.field(parts, "title")
  let assert Ok(avatar) = multipartkit.file(parts, "avatar")

  io.println("Content-Type: " <> content_type)
  io.println("title=" <> title)
  io.println(
    "avatar filename=" <> option.unwrap(multipartkit.filename(avatar), ""),
  )
  let size = bit_array.byte_size(multipartkit.body(avatar))
  io.println("avatar size=" <> int.to_string(size))
}
```

```text
Content-Type: multipart/form-data; boundary=----multipartkit-y9o53iydy0zm2dxbmbhvbsi9
title=hello
avatar filename=cat.png
avatar size=4
```

In a request handler, chain the lookups with `result.try` and use tighter limits than `default_limits` on a public endpoint:

```gleam
pub fn read_upload(body: BitArray, content_type: String) {
  let limits = multipartkit.Limits(..multipartkit.default_limits, max_parts: 10)
  use parts <- result.try(multipartkit.parse(body, content_type, limits))
  use title <- result.try(multipartkit.field(parts, "title"))
  use avatar <- result.try(multipartkit.file(parts, "avatar"))
  use avatar <- result.try(
    multipartkit.allowed_content_types(avatar, ["image/png", "image/jpeg"]),
  )
  Ok(#(title, avatar))
}
```

`multipartkit.infer_content_type(filename, bytes)` picks a content type for `new_file` from the file name or its first bytes. `stream.parse` takes a `Yielder(BitArray)` of chunks and hands out each part body as chunks of up to 64 KiB; see [`examples/streaming_parse`](https://github.com/nao1215/multipartkit/tree/main/examples/streaming_parse).

The API reference is on [HexDocs](https://hexdocs.pm/multipartkit/).

## Notes

- `filename` returns what the client sent, which can be `../../etc/passwd` or an absolute path. Do not join it onto a server path; name stored files after a hash of their bytes or a generated id.
- The Content-Type of a part is also what the client sent. Check the bytes with `infer_content_type` or [`mimetype.detect`](https://hexdocs.pm/mimetype/mimetype.html#detect) when it matters.
- `new_field`, `new_file` and `new_part` reject CR, LF and NUL in names, filenames and header values, so a value from a user cannot add header lines.
- `new_file` writes a non-ASCII filename as UTF-8 in the quoted `filename` parameter, as browsers do, because RFC 7578 forbids `filename*` in form data. `parse` still reads a `filename*` that another client sends, in UTF-8 or ISO-8859-1, and prefers it to `filename`, as Go and Python do. One it cannot decode is ignored.
- `encode` returns `InvalidBoundary` when a line of a part starts with `--` and the boundary, which the receiver would take for a delimiter. `encode_form` draws a new boundary instead.

How the package is tested is described in [doc/testing.md](https://github.com/nao1215/multipartkit/blob/main/doc/testing.md).

## Verifying releases

Each GitHub Release attaches the tarball published to Hex (`multipartkit-<version>.tar`), `checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and build provenance (`multipartkit-<version>.intoto.jsonl`). The release workflow downloads the tarball from Hex after `gleam publish` and checks it against the checksum Hex records before signing it, so the tarball you get from Hex is the one that is signed and attested.

```sh
curl -fsSLO https://repo.hex.pm/tarballs/multipartkit-<version>.tar
gh attestation verify multipartkit-<version>.tar --repo nao1215/multipartkit
```

To check the signature as well, download `checksums.txt` and `checksums.txt.sigstore.json` from the Release into the same directory. The workflow runs on the release tag, or on `main` when the assets of a published tag are attached again.

```sh
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/nao1215/multipartkit/\.github/workflows/release\.yml@refs/(tags/v.+|heads/main)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check checksums.txt
```

## License

[MIT](https://github.com/nao1215/multipartkit/blob/main/LICENSE)
