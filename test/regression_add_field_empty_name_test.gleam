//// Regression tests for Issues #57 and #58: the lenient
//// `multipartkit/form.add_field` must never let an empty `name`
//// (whether passed empty, or stripped to empty by CR / LF / NUL
//// removal) reach the wire as `Content-Disposition: form-data;
//// name=""`.
////
//// RFC 7578 §4.2 says the `name` parameter is the field name; an empty
//// name produces a wire image whose receiver interpretation is
//// implementation-defined. The strict `add_field_strict` rejects such
//// input with `Error(EmptyFieldName(_))`; the lenient `add_field`
//// instead renames the part to a generated `"_unnamed_<n>"` placeholder
//// (option 2 of the issue: normalise loudly) so the observable `name`
//// is never `Some("")`.

import gleam/list
import gleam/option.{Some}
import gleeunit/should
import multipartkit
import multipartkit/form
import multipartkit/part

// Names that are empty after CR / LF / NUL stripping. Each must round-trip
// to a non-empty name rather than Some("").
const blank_after_strip = ["", "\n", "\r", "\r\n", "\u{0000}"]

pub fn add_field_empty_name_never_round_trips_to_empty_test() {
  list.each(blank_after_strip, fn(bad) {
    let f = form.new() |> form.add_field(name: bad, value: "x")
    let #(ct, body) = multipartkit.encode_form(f)
    let assert Ok(parts) = multipartkit.parse(body, ct)
    case parts {
      [p, ..] -> part.name(p) |> should.not_equal(Some(""))
      [] -> should.fail()
    }
  })
}

pub fn add_field_empty_name_uses_placeholder_test() {
  let f = form.new() |> form.add_field(name: "", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some("_unnamed_0"))
}

pub fn add_field_crlf_only_name_uses_placeholder_test() {
  // CR/LF/NUL-only names strip to "" and therefore get the placeholder.
  let f = form.new() |> form.add_field(name: "\r\n", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some("_unnamed_0"))
}

pub fn add_field_whitespace_only_name_uses_placeholder_test() {
  // Whitespace-only names are blank per RFC 7578 and also get renamed,
  // matching the "empty" notion that add_field_strict rejects.
  let f = form.new() |> form.add_field(name: "   ", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some("_unnamed_0"))
}

pub fn add_field_partially_stripped_name_kept_test() {
  // "ab\ncd" strips to "abcd" which is non-empty, so it is kept as-is and
  // NOT replaced with a placeholder.
  let f = form.new() |> form.add_field(name: "ab\ncd", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some("abcd"))
}

pub fn add_field_padded_name_kept_test() {
  // A name that merely has surrounding whitespace is kept verbatim — only
  // an entirely blank name is rewritten.
  let f = form.new() |> form.add_field(name: " a ", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some(" a "))
}

pub fn add_field_normal_name_unchanged_test() {
  let f = form.new() |> form.add_field(name: "foo", value: "x")
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([p]) = multipartkit.parse(body, ct)
  part.name(p) |> should.equal(Some("foo"))
}

pub fn add_field_placeholder_index_tracks_position_test() {
  // Each blank-named part gets a distinct placeholder based on its
  // zero-based position, so multiple empty names do not collide.
  let f =
    form.new()
    |> form.add_field(name: "", value: "a")
    |> form.add_field(name: "kept", value: "b")
    |> form.add_field(name: "\n", value: "c")
  let names = form.parts(f) |> list.map(part.name)
  names
  |> should.equal([Some("_unnamed_0"), Some("kept"), Some("_unnamed_2")])
}
