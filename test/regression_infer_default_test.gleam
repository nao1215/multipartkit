//// Regression tests for Issue #59: `multipartkit/infer.content_type_from_filename`
//// and `content_type_from_bytes` must resolve well-known types instead of
//// always returning `None`.
////
//// These helpers now delegate to `nao1215/mimetype`: they return
//// `Some(mime)` for a recognised extension / magic-byte signature and
//// `None` for unknown input. This supersedes the earlier #52 contract that
//// pinned them as default no-ops.
////
//// `default_inferer()` is intentionally still a no-op (inference into the
//// form builder is opt-in via `builtin_inferer()` / `add_file_auto_with`),
//// so its behaviour is pinned separately below.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/infer

// === content_type_from_filename: known extensions resolve (#59 DoD) ===

pub fn content_type_from_filename_returns_known_test() {
  let cases = [
    #("a.png", "image/png"),
    #("a.jpg", "image/jpeg"),
    #("a.jpeg", "image/jpeg"),
    #("a.gif", "image/gif"),
    #("a.pdf", "application/pdf"),
    #("a.json", "application/json"),
    #("a.txt", "text/plain"),
    #("a.csv", "text/csv"),
    #("a.html", "text/html"),
  ]
  list.each(cases, fn(c) {
    let #(name, expected) = c
    infer.content_type_from_filename(name) |> should.equal(Some(expected))
  })
}

pub fn content_type_from_filename_unknown_test() {
  infer.content_type_from_filename("a.zzznosuch") |> should.equal(None)
  infer.content_type_from_filename("") |> should.equal(None)
}

// === content_type_from_bytes: magic-byte signatures resolve (#59 DoD) ===

pub fn content_type_from_bytes_magic_test() {
  // PNG signature
  let png = <<0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a>>
  infer.content_type_from_bytes(png) |> should.equal(Some("image/png"))

  // JPEG SOI + APP0
  let jpeg = <<0xff, 0xd8, 0xff, 0xe0>>
  infer.content_type_from_bytes(jpeg) |> should.equal(Some("image/jpeg"))

  // PDF
  let pdf = <<"%PDF-1.4":utf8>>
  infer.content_type_from_bytes(pdf) |> should.equal(Some("application/pdf"))

  // GIF87a
  let gif = <<"GIF87a":utf8>>
  infer.content_type_from_bytes(gif) |> should.equal(Some("image/gif"))
}

pub fn content_type_from_bytes_empty_returns_none_test() {
  infer.content_type_from_bytes(<<>>) |> should.equal(None)
}

// === default_inferer() stays a no-op (form-builder inference is opt-in) ===

pub fn default_inferer_from_filename_still_none_test() {
  let inferer = infer.default_inferer()
  inferer.from_filename("photo.png") |> should.equal(None)
}

pub fn default_inferer_from_bytes_still_none_test() {
  let inferer = infer.default_inferer()
  inferer.from_bytes(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  |> should.equal(None)
}

// === builtin_inferer() exposes the mimetype-backed inference ===

pub fn builtin_inferer_from_filename_resolves_test() {
  let inferer = infer.builtin_inferer()
  inferer.from_filename("photo.png") |> should.equal(Some("image/png"))
}

pub fn builtin_inferer_from_bytes_resolves_test() {
  let inferer = infer.builtin_inferer()
  inferer.from_bytes(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  |> should.equal(Some("image/png"))
}
