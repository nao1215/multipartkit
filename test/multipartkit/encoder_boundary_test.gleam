//// Boundary validation on the encode path. Pinning the rejection
//// behaviour added in #34 — the encoder now refuses CR / LF / NUL /
//// non-`bchars` boundaries up-front instead of silently emitting a
//// wire image whose framing bytes inject forged headers.

import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import gleeunit/should
import multipartkit
import multipartkit/encoder
import multipartkit/error.{InvalidBoundary}
import multipartkit/form
import multipartkit/part
import multipartkit/stream

fn single_part() -> part.Part {
  let assert Ok(p) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"v":utf8>>,
    )
  p
}

// --- encode/2 rejection cases ---

pub fn encode_rejects_empty_boundary_test() {
  encoder.encode("", [single_part()])
  |> should.equal(Error(InvalidBoundary("")))
}

pub fn encode_rejects_overlong_boundary_test() {
  // 71 chars: one over the RFC 2046 §5.1.1 ceiling.
  let boundary = string.repeat("a", 71)
  encoder.encode(boundary, [single_part()])
  |> should.equal(Error(InvalidBoundary(boundary)))
}

pub fn encode_rejects_cr_in_boundary_test() {
  let attack = "abc\r\nContent-Type: text/html\r\n\r\nGOTCHA"
  encoder.encode(attack, [single_part()])
  |> should.equal(Error(InvalidBoundary(attack)))
}

pub fn encode_rejects_lf_in_boundary_test() {
  encoder.encode("ab\nc", [single_part()])
  |> should.equal(Error(InvalidBoundary("ab\nc")))
}

pub fn encode_rejects_nul_in_boundary_test() {
  let attack = "ab\u{0000}c"
  encoder.encode(attack, [single_part()])
  |> should.equal(Error(InvalidBoundary(attack)))
}

pub fn encode_rejects_trailing_space_boundary_test() {
  // Spaces are valid mid-boundary but RFC 2046 forbids a trailing space.
  encoder.encode("abc ", [single_part()])
  |> should.equal(Error(InvalidBoundary("abc ")))
}

// --- encode/2 accepts valid boundaries ---

pub fn encode_accepts_alphanumeric_boundary_test() {
  let assert Ok(_) = encoder.encode("Abc123", [single_part()])
}

pub fn encode_accepts_max_length_boundary_test() {
  let boundary = string.repeat("a", 70)
  let assert Ok(_) = encoder.encode(boundary, [single_part()])
}

pub fn encode_accepts_punctuation_boundary_test() {
  // All listed `bchars` (RFC 2046 §5.1.1).
  let assert Ok(_) = encoder.encode("'()+_,-./:=?abc", [single_part()])
}

// --- facade re-export keeps the same shape ---

pub fn facade_encode_returns_error_test() {
  multipartkit.encode("ab\rc", [single_part()])
  |> should.equal(Error(InvalidBoundary("ab\rc")))
}

// --- encode_form regression: internal boundary always passes ---

pub fn encode_form_internal_boundary_always_valid_test() {
  // Sanity check: encode_form never trips its own validator. If
  // generate_boundary regresses, the let assert in encoder.encode_form
  // will panic before reaching this assertion.
  let f =
    form.new()
    |> form.add_field("k", "v")
  let #(content_type, body) = encoder.encode_form(f)
  case string.starts_with(content_type, "multipart/form-data; boundary=") {
    True -> Nil
    False -> should.fail()
  }
  // body must be non-empty and end with the closing delimiter.
  let assert Ok(body_str) = bit_array.to_string(body)
  string.contains(body_str, "----multipartkit-")
  |> should.be_true
}

// --- encode_stream surfaces invalid boundary as the first item ---

pub fn encode_stream_invalid_boundary_yields_error_test() {
  let stream_part = stream.from_part(single_part())
  let chunks = encoder.encode_stream("ab\rc", yielder.from_list([stream_part]))
  case yielder.step(chunks) {
    yielder.Next(Error(InvalidBoundary("ab\rc")), _) -> Nil
    _ -> should.fail()
  }
}

pub fn encode_stream_valid_boundary_proceeds_test() {
  let stream_part = stream.from_part(single_part())
  let chunks = encoder.encode_stream("ok", yielder.from_list([stream_part]))
  // First emission must be Ok (the dash prefix). We don't drain the
  // whole stream here — encoder_test already pins the round-trip.
  case yielder.step(chunks) {
    yielder.Next(Ok(_), _) -> Nil
    _ -> should.fail()
  }
}
