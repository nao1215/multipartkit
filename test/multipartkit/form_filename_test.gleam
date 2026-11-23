//// RFC 7578 §4.2 for the filenames `new_file` writes: a filename outside
//// ASCII goes in the quoted `filename` parameter as UTF-8, as browsers send
//// it, and the RFC 5987 `filename*` parameter is never written.

import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import multipartkit
import support

fn encoded_text(filename: String) -> String {
  let parts =
    [] |> support.add_file("file", filename, "application/pdf", <<"x":utf8>>)
  let assert Ok(body) = multipartkit.encode(parts, "bnd")
  let assert Ok(text) = bit_array.to_string(body)
  text
}

fn round_trip(filename: String) -> option.Option(String) {
  let parts =
    [] |> support.add_file("file", filename, "application/pdf", <<"x":utf8>>)
  let #(content_type, body) = multipartkit.encode_form(parts)
  let assert Ok([part]) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  multipartkit.filename(part)
}

pub fn ascii_filename_is_quoted_test() {
  let text = encoded_text("doc.pdf")
  string.contains(text, "; filename=\"doc.pdf\"\r\n") |> should.be_true
}

pub fn non_ascii_filenames_are_written_as_utf8_test() {
  ["写真.png", "Naïve.txt", "globe🌏.png", "e\u{0301}.txt"]
  |> list.each(fn(filename) {
    let text = encoded_text(filename)
    string.contains(text, "; filename=\"" <> filename <> "\"\r\n")
    |> should.be_true
    string.contains(text, "filename*") |> should.be_false
    round_trip(filename) |> should.equal(Some(filename))
  })
}

pub fn quote_and_backslash_are_escaped_test() {
  let text = encoded_text("a\"b\\c.txt")
  string.contains(text, "filename=\"a\\\"b\\\\c.txt\"") |> should.be_true
  round_trip("a\"b\\c.txt") |> should.equal(Some("a\"b\\c.txt"))
}

pub fn control_characters_other_than_cr_lf_nul_round_trip_test() {
  // A quoted string holds them as they are, as browsers send them.
  ["\t", "\u{0001}", "\u{001F}", "\u{007F}"]
  |> list.each(fn(control) {
    let filename = "a" <> control <> "b"
    string.contains(encoded_text(filename), "filename*") |> should.be_false
    round_trip(filename) |> should.equal(Some(filename))
  })
}
