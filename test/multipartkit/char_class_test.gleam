//// Exhaustive character-class tables: every ASCII code point is checked
//// against the grammar written out from the RFC, so a range check that is
//// off by one or a missing entry in a long `||` chain fails here.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import multipartkit
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

pub fn ext_value_accepts_exactly_attr_chars_test() {
  // RFC 5987 §3.2.1 value-chars := *( pct-encoded / attr-char ). The value
  // is quoted so that the token rules do not decide first.
  ascii()
  |> list.each(fn(code) {
    let escaped = case code {
      0x22 -> "\\\""
      0x5C -> "\\\\"
      _ -> char(code)
    }
    let value = "attachment; filename*=\"UTF-8''a" <> escaped <> "b\""
    case multipartkit.parse_content_disposition(value), is_attr_char(code) {
      Ok(parsed), True ->
        parsed.filename |> should.equal(Some("a" <> char(code) <> "b"))
      Error(_), False -> Nil
      _, valid -> should.equal(#(code, valid), #(code, !valid))
    }
  })
}

pub fn every_filename_byte_but_cr_lf_nul_round_trips_test() {
  // new_file rejects CR, LF and NUL. Every other ASCII byte goes in the
  // quoted `filename` as it is, never in `filename*` (RFC 7578 §4.2).
  ascii()
  |> list.filter(fn(code) { code != 0x00 && code != 0x0A && code != 0x0D })
  |> list.each(fn(code) {
    let filename = "a" <> char(code) <> "b"
    let header = disposition.build_form_data_value("f", Some(filename))
    string.contains(header, "filename*") |> should.be_false
    let assert Ok(parsed) = multipartkit.parse_content_disposition(header)
    parsed.filename |> should.equal(Some(filename))
  })
}

/// RFC 7230 §3.2.6 quoted-pair: "\" ( HTAB / SP / VCHAR / obs-text ).
pub fn quoted_pair_accepts_exactly_htab_sp_vchar_and_obs_text_test() {
  [0x00E9, 0x3042, ..ascii()]
  |> list.each(fn(code) {
    let value = "form-data; name=\"a\\" <> char(code) <> "b\""
    let valid = code == 0x09 || { code >= 0x20 && code != 0x7F }
    case multipartkit.parse_content_disposition(value), valid {
      Ok(parsed), True ->
        parsed.name
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
    let assert Ok(parsed) = multipartkit.parse_content_disposition(header)
    parsed.filename |> should.equal(Some(filename))
    parsed.name |> should.equal(Some("f"))
  })
  disposition.build_form_data_value("f", None)
  |> multipartkit.parse_content_disposition
  |> should.be_ok
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
