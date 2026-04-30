//// RFC 5987 / RFC 6266 §4.3 conformance for the encoder side of
//// `form.add_file`. When the filename contains bytes outside the
//// printable US-ASCII range, the encoder must emit BOTH the legacy
//// `filename="<ascii-fallback>"` form AND the RFC 5987 `filename*=`
//// form so the wire stays valid under RFC 7230 §3.2.4 and is still
//// readable by spec-aware parsers.

import gleam/bit_array
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import multipartkit
import multipartkit/encoder
import multipartkit/form
import multipartkit/parser
import multipartkit/part

// ---------------------------------------------------------------
// ASCII-only filename: behaviour MUST be unchanged from before this
// fix. No `filename*=` is emitted, and the legacy `filename="..."`
// keeps the same shape it always had.
// ---------------------------------------------------------------

pub fn ascii_filename_keeps_legacy_form_only_test() {
  let f =
    form.new()
    |> form.add_file("file", "doc.pdf", "application/pdf", <<"PDF":utf8>>)
  let body = encoder.encode("bnd", form.parts(f))
  let assert Ok(body_str) = bit_array.to_string(body)
  string.contains(body_str, "filename=\"doc.pdf\"")
  |> should.be_true
  string.contains(body_str, "filename*=")
  |> should.be_false
}

// ---------------------------------------------------------------
// CJK filename: the encoder must emit BOTH forms.
//   filename="<ascii-fallback>"
//   filename*=UTF-8''<percent-encoded>
// where the percent-encoded UTF-8 of `写真.png` is
// `%E5%86%99%E7%9C%9F.png` (the `.` is attr-char and passes through).
// ---------------------------------------------------------------

pub fn cjk_filename_emits_both_legacy_and_rfc5987_test() {
  let f =
    form.new()
    |> form.add_file("file", "写真.png", "image/png", <<"ASCII":utf8>>)
  let body = encoder.encode("bnd", form.parts(f))
  let assert Ok(body_str) = bit_array.to_string(body)
  // Must NOT contain the raw CJK bytes inside the header any more.
  string.contains(body_str, "filename=\"写真.png\"")
  |> should.be_false
  // Must contain the percent-encoded RFC 5987 form.
  string.contains(body_str, "filename*=UTF-8''%E5%86%99%E7%9C%9F.png")
  |> should.be_true
  // Must contain a sanitised legacy form (non-ASCII → `_`).
  string.contains(body_str, "filename=\"__.png\"")
  |> should.be_true
}

// ---------------------------------------------------------------
// Round-trip: encoder emits both forms, parser prefers `filename*=`
// per RFC 5987 §3.2.2 (and per multipartkit's own
// content_disposition.parse doc-comment).
// ---------------------------------------------------------------

pub fn cjk_filename_round_trips_via_rfc5987_test() {
  let f =
    form.new()
    |> form.add_file("file", "写真.png", "image/png", <<"ASCII":utf8>>)
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([the_part]) = parser.parse(body, ct)
  part.filename(the_part) |> should.equal(Some("写真.png"))
}

// ---------------------------------------------------------------
// Latin-1 supplement: `Naïve.txt`. UTF-8 bytes for `ï` are `C3 AF`,
// for `é` (not in this case) etc. The percent-encoded form must
// preserve the surrounding ASCII characters (`Na...ve.txt`) and only
// encode the non-ASCII bytes.
// ---------------------------------------------------------------

pub fn latin_supplement_filename_emits_rfc5987_test() {
  let f =
    form.new()
    |> form.add_file("file", "Naïve.txt", "text/plain", <<"x":utf8>>)
  let body = encoder.encode("bnd", form.parts(f))
  let assert Ok(body_str) = bit_array.to_string(body)
  string.contains(body_str, "filename*=UTF-8''Na%C3%AFve.txt")
  |> should.be_true
  // Legacy form: ï replaced with `_`.
  string.contains(body_str, "filename=\"Na_ve.txt\"")
  |> should.be_true
}

pub fn latin_filename_round_trips_test() {
  let f =
    form.new()
    |> form.add_file("file", "Naïve.txt", "text/plain", <<"x":utf8>>)
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([the_part]) = parser.parse(body, ct)
  part.filename(the_part) |> should.equal(Some("Naïve.txt"))
}

// ---------------------------------------------------------------
// Emoji filename: 4-byte UTF-8 sequence. UTF-8 for 🌏 (U+1F30F) is
// F0 9F 8C 8F.
// ---------------------------------------------------------------

pub fn emoji_filename_round_trips_test() {
  let f =
    form.new()
    |> form.add_file("file", "globe🌏.png", "image/png", <<"x":utf8>>)
  let #(ct, body) = multipartkit.encode_form(f)
  let assert Ok([the_part]) = parser.parse(body, ct)
  part.filename(the_part) |> should.equal(Some("globe🌏.png"))
}

// ---------------------------------------------------------------
// Pure ASCII with characters that need quote-escape inside the
// legacy form ("a\"b.txt") still need to be quoted/escaped, and the
// legacy form is sufficient — no `filename*=`.
// ---------------------------------------------------------------

pub fn ascii_filename_with_quote_keeps_legacy_only_test() {
  let f =
    form.new()
    |> form.add_file("file", "a\"b.txt", "text/plain", <<"x":utf8>>)
  let body = encoder.encode("bnd", form.parts(f))
  let assert Ok(body_str) = bit_array.to_string(body)
  string.contains(body_str, "filename=\"a\\\"b.txt\"")
  |> should.be_true
  string.contains(body_str, "filename*=")
  |> should.be_false
  // And it still round-trips:
  let #(ct, body2) = multipartkit.encode_form(f)
  let assert Ok([p]) = parser.parse(body2, ct)
  part.filename(p) |> should.equal(Some("a\"b.txt"))
}
