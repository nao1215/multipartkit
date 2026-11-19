//// Exhaustive character-class tables: every ASCII code point is checked
//// against the grammar written out from the RFC, so a range check that is
//// off by one or a missing entry in a long `||` chain fails here.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import multipartkit/content_disposition
import multipartkit/internal/disposition

fn ascii() -> List(Int) {
  range(0, 127)
}

fn char(code: Int) -> String {
  let assert Ok(cp) = string.utf_codepoint(code)
  string.from_utf_codepoints([cp])
}

/// RFC 5987 §3.2.1 attr-char: ALPHA / DIGIT / "!" / "#" / "$" / "&" /
/// "+" / "-" / "." / "^" / "_" / "`" / "|" / "~".
fn is_attr_char(code: Int) -> Bool {
  { code >= 0x41 && code <= 0x5A }
  || { code >= 0x61 && code <= 0x7A }
  || { code >= 0x30 && code <= 0x39 }
  || list.contains([0x21, 0x23, 0x24, 0x26, 0x2B, 0x2D, 0x2E], code)
  || list.contains([0x5E, 0x5F, 0x60, 0x7C, 0x7E], code)
}

fn percent(code: Int) -> String {
  "%" <> string.pad_start(int.to_base16(code), to: 2, with: "0")
}

pub fn filename_star_encodes_exactly_the_non_attr_chars_test() {
  // A non-ASCII grapheme forces the RFC 5987 `filename*` form; the byte
  // after it must stay literal if and only if it is an attr-char.
  range(0x20, 0x7E)
  |> list.each(fn(code) {
    let header =
      disposition.build_form_data_value("f", Some("\u{00E9}" <> char(code)))
    let expected = case is_attr_char(code) {
      True -> char(code)
      False -> percent(code)
    }
    let assert Ok(#(_, star)) = string.split_once(header, "filename*=UTF-8''")
    star |> should.equal("%C3%A9" <> expected)
  })
}

pub fn plain_filename_is_used_only_for_printable_ascii_and_tab_test() {
  // Bytes outside HTAB / SP..~ (except the CR, LF and NUL that form
  // building strips) need the `filename*` form.
  ascii()
  |> list.filter(fn(code) { code != 0x00 && code != 0x0A && code != 0x0D })
  |> list.each(fn(code) {
    let header = disposition.build_form_data_value("f", Some("a" <> char(code)))
    let safe = code == 0x09 || { code >= 0x20 && code <= 0x7E }
    string.contains(header, "filename*=") |> should.equal(!safe)
  })
}

/// RFC 7230 §3.2.6 quoted-pair: "\" ( HTAB / SP / VCHAR / obs-text ).
pub fn quoted_pair_accepts_exactly_htab_sp_vchar_and_obs_text_test() {
  [0x00E9, 0x3042, ..ascii()]
  |> list.each(fn(code) {
    let value = "form-data; name=\"a\\" <> char(code) <> "b\""
    let valid = code == 0x09 || { code >= 0x20 && code != 0x7F }
    case content_disposition.parse(value), valid {
      Ok(parsed), True ->
        content_disposition.name(parsed)
        |> should.equal(Some("a" <> char(code) <> "b"))
      Error(_), False -> Nil
      _, _ -> should.equal(#(code, valid), #(code, !valid))
    }
  })
}

pub fn plain_filename_round_trips_every_printable_ascii_char_test() {
  // The quoted `filename=` form escapes `"` and `\`, so parsing the
  // header back returns the original printable-ASCII filename.
  range(0x20, 0x7E)
  |> list.each(fn(code) {
    let filename = "x" <> char(code) <> "y"
    let header = disposition.build_form_data_value("f", Some(filename))
    let assert Ok(parsed) = content_disposition.parse(header)
    content_disposition.filename(parsed) |> should.equal(Some(filename))
    content_disposition.name(parsed) |> should.equal(Some("f"))
  })
  disposition.build_form_data_value("f", None)
  |> content_disposition.parse
  |> should.be_ok
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
