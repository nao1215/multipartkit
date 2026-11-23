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
/// A filename made of printable ASCII uses the plain `filename="..."` form.
/// Any other filename also gets an RFC 5987 `filename*=UTF-8''...` parameter,
/// with `_` replacing the non-ASCII characters in the plain one. The caller
/// rejects CR, LF and NUL before calling this.
pub fn build_form_data_value(name: String, filename: Option(String)) -> String {
  let base = "form-data; name=" <> quote(name)
  case filename {
    None -> base
    Some(fname) -> base <> filename_disposition_params(fname)
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
/// parameter. Supports UTF-8 and ISO-8859-1, and fails when the value decodes
/// to CR, LF or NUL.
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
    ["%", high, low, ..rest] -> {
      use byte <- result.try(hex_pair(high, low))
      percent_decode(rest, <<acc:bits, byte>>)
    }
    ["%", ..] -> Error(Nil)
    [other, ..rest] -> percent_decode(rest, <<acc:bits, other:utf8>>)
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

fn filename_disposition_params(filename: String) -> String {
  case is_ascii_safe(bit_array.from_string(filename)) {
    True -> "; filename=" <> quote(filename)
    False ->
      "; filename="
      <> quote(ascii_fallback(string.to_graphemes(filename), ""))
      <> "; filename*=UTF-8''"
      <> percent_encode(bit_array.from_string(filename), "")
  }
}

fn is_ascii_safe(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<b, rest:bytes>> ->
      case b == 0x09 || { b >= 0x20 && b <= 0x7E } {
        True -> is_ascii_safe(rest)
        False -> False
      }
    _ -> False
  }
}

fn ascii_fallback(remaining: List(String), acc: String) -> String {
  case remaining {
    [] -> acc
    [grapheme, ..rest] ->
      case is_ascii_safe(bit_array.from_string(grapheme)) {
        True -> ascii_fallback(rest, acc <> grapheme)
        False -> ascii_fallback(rest, acc <> "_")
      }
  }
}

fn percent_encode(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<b, rest:bytes>> -> {
      let chunk = case is_attr_char(b) {
        True -> result.unwrap(bit_array.to_string(<<b>>), "")
        False -> percent_byte(b)
      }
      percent_encode(rest, acc <> chunk)
    }
    _ -> acc
  }
}

fn is_attr_char(b: Int) -> Bool {
  // ALPHA / DIGIT
  { b >= 0x41 && b <= 0x5A }
  || { b >= 0x61 && b <= 0x7A }
  || { b >= 0x30 && b <= 0x39 }
  // ! # $ & + - . ^ _ ` | ~
  || b == 0x21
  || b == 0x23
  || b == 0x24
  || b == 0x26
  || b == 0x2B
  || b == 0x2D
  || b == 0x2E
  || b == 0x5E
  || b == 0x5F
  || b == 0x60
  || b == 0x7C
  || b == 0x7E
}

fn percent_byte(b: Int) -> String {
  "%" <> string.pad_start(int.to_base16(b), to: 2, with: "0")
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
