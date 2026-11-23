//// Internal: building and decoding `Content-Disposition` parameter values.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import multipartkit/internal/text

/// Internal: Build the `Content-Disposition` value for a form-data part.
///
/// The name and filename are quoted strings in UTF-8, as browsers send
/// them. RFC 7578 §4.2 forbids the RFC 5987 `filename*` parameter here. The
/// caller rejects CR, LF and NUL before calling this.
pub fn build_form_data_value(name: String, filename: Option(String)) -> String {
  let base = "form-data; name=" <> quote(name)
  case filename {
    None -> base
    Some(filename) -> base <> "; filename=" <> quote(filename)
  }
}

/// Internal: True when `value` contains CR, LF or NUL, the bytes that would
/// split a header value into more than one line.
pub fn has_header_breaking_bytes(value: String) -> Bool {
  string.contains(value, "\r")
  || string.contains(value, "\n")
  || string.contains(value, "\u{0000}")
}

/// Internal: Decode an RFC 5987 / RFC 8187 `charset'language'value`
/// parameter. Supports UTF-8 and ISO-8859-1. Fails when the value holds a
/// character that is neither an `attr-char` nor `%` with two hex digits, or
/// decodes to CR, LF or NUL.
pub fn decode_extended_value(input: String) -> Result(String, Nil) {
  use #(charset, after_first) <- result.try(string.split_once(input, on: "'"))
  use #(_language, encoded) <- result.try(string.split_once(after_first, "'"))
  use bytes <- result.try(percent_decode(string.to_graphemes(encoded), <<>>))
  use decoded <- result.try(case text.ascii_lowercase(charset) {
    "utf-8" -> bit_array.to_string(bytes)
    "iso-8859-1" -> Ok(latin1_to_utf8(bytes, ""))
    _ -> Error(Nil)
  })
  // The quoted form cannot carry these bytes either (#50).
  case has_header_breaking_bytes(decoded) {
    True -> Error(Nil)
    False -> Ok(decoded)
  }
}

fn latin1_to_utf8(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<byte, rest:bytes>> ->
      latin1_to_utf8(rest, acc <> code_point_to_string(byte))
    _ -> acc
  }
}

fn code_point_to_string(byte: Int) -> String {
  case string.utf_codepoint(byte) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(Nil) -> ""
  }
}

fn percent_decode(
  remaining: List(String),
  acc: BitArray,
) -> Result(BitArray, Nil) {
  case remaining {
    [] -> Ok(acc)
    // A plain `case`, so the recursion is a tail call on JavaScript too.
    ["%", high, low, ..rest] ->
      case hex_pair(high, low) {
        Ok(byte) -> percent_decode(rest, <<acc:bits, byte>>)
        Error(Nil) -> Error(Nil)
      }
    ["%", ..] -> Error(Nil)
    [other, ..rest] ->
      case is_attr_char(other) {
        True -> percent_decode(rest, <<acc:bits, other:utf8>>)
        False -> Error(Nil)
      }
  }
}

fn hex_pair(high: String, low: String) -> Result(Int, Nil) {
  use h <- result.try(hex_digit(high))
  use l <- result.try(hex_digit(low))
  Ok(h * 16 + l)
}

fn hex_digit(grapheme: String) -> Result(Int, Nil) {
  // `int.base_parse` also accepts a sign, so check the character first.
  use <- bool.guard(
    when: !string.contains("0123456789abcdefABCDEF", grapheme),
    return: Error(Nil),
  )
  int.base_parse(grapheme, 16)
}

/// RFC 5987 §3.2.1 attr-char: ALPHA / DIGIT / "!" / "#" / "$" / "&" / "+" /
/// "-" / "." / "^" / "_" / "`" / "|" / "~".
fn is_attr_char(grapheme: String) -> Bool {
  case bit_array.from_string(grapheme) {
    <<b>> ->
      { b >= 0x41 && b <= 0x5A }
      || { b >= 0x61 && b <= 0x7A }
      || { b >= 0x30 && b <= 0x39 }
      || string.contains("!#$&+-.^_`|~", grapheme)
    _ -> False
  }
}

fn quote(value: String) -> String {
  let escaped = escape_quoted(bit_array.from_string(value), <<>>)
  // Only ASCII bytes were inserted, so the result is still UTF-8.
  "\"" <> result.unwrap(bit_array.to_string(escaped), "") <> "\""
}

fn escape_quoted(remaining: BitArray, acc: BitArray) -> BitArray {
  // Work on bytes: a quote followed by a combining mark is one grapheme, and
  // would not be escaped if this compared graphemes.
  case remaining {
    <<"\\":utf8, rest:bytes>> -> escape_quoted(rest, <<acc:bits, "\\\\":utf8>>)
    <<"\"":utf8, rest:bytes>> -> escape_quoted(rest, <<acc:bits, "\\\"":utf8>>)
    <<byte, rest:bytes>> -> escape_quoted(rest, <<acc:bits, byte>>)
    _ -> acc
  }
}
