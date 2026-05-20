//// Regression tests for Issue #52: `multipartkit/infer.content_type_from_filename`
//// and `content_type_from_bytes` are documented **default no-ops** of the
//// pluggable inference interface — they always return `None` for every
//// input, including well-known extensions and magic-byte signatures.
////
//// These tests pin the no-op behaviour so a future implementation change
//// (e.g. wiring in `nao1215/mimetype` at the top level) cannot ship
//// silently against the documented contract called out in `infer.gleam`
//// and `README.md`.

import gleam/option.{None}
import gleeunit/should
import multipartkit/infer

// === Documented no-op: filename-based inference always returns None ===

pub fn infer_default_returns_none_test() {
  // The two assertions from Issue #52: known extension and known magic
  // bytes both fall through to `None`.
  infer.content_type_from_filename("photo.png") |> should.equal(None)
  infer.content_type_from_bytes(<<137, 80, 78, 71>>) |> should.equal(None)
}

pub fn infer_default_filename_pdf_returns_none_test() {
  infer.content_type_from_filename("doc.pdf") |> should.equal(None)
}

pub fn infer_default_filename_js_returns_none_test() {
  infer.content_type_from_filename("script.js") |> should.equal(None)
}

pub fn infer_default_filename_html_returns_none_test() {
  infer.content_type_from_filename("page.html") |> should.equal(None)
}

pub fn infer_default_filename_empty_returns_none_test() {
  infer.content_type_from_filename("") |> should.equal(None)
}

// === Documented no-op: byte-based inference always returns None ===

pub fn infer_default_bytes_full_png_signature_returns_none_test() {
  // Full 8-byte PNG signature: still None under the default no-op.
  infer.content_type_from_bytes(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  |> should.equal(None)
}

pub fn infer_default_bytes_jpeg_signature_returns_none_test() {
  // JPEG SOI marker (FFD8FF) — still None.
  infer.content_type_from_bytes(<<0xFF, 0xD8, 0xFF>>) |> should.equal(None)
}

pub fn infer_default_bytes_pdf_signature_returns_none_test() {
  // "%PDF-" — still None.
  infer.content_type_from_bytes(<<0x25, 0x50, 0x44, 0x46, 0x2D>>)
  |> should.equal(None)
}

pub fn infer_default_bytes_empty_returns_none_test() {
  infer.content_type_from_bytes(<<>>) |> should.equal(None)
}

// === `default_inferer()` exposes the same no-op behaviour ===

pub fn infer_default_inferer_from_filename_returns_none_test() {
  let inferer = infer.default_inferer()
  inferer.from_filename("photo.png") |> should.equal(None)
}

pub fn infer_default_inferer_from_bytes_returns_none_test() {
  let inferer = infer.default_inferer()
  inferer.from_bytes(<<137, 80, 78, 71, 13, 10, 26, 10>>)
  |> should.equal(None)
}
