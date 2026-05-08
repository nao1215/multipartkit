//// Internal: helpers for building `Content-Disposition` header values
//// (the `form-data; name="..."[; filename=...]` shape) and for stripping
//// CR / LF / NUL bytes that would otherwise smuggle additional header
//// lines into the encoded wire image. Shared by `multipartkit/form` (which
//// builds parts from raw values) and `multipartkit/part` (which synthesises
//// missing headers when `new/5` is given `name` / `filename` /
//// `content_type` cache values without the corresponding header entries).

import gleam/bit_array
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Build the full `Content-Disposition` header value for a `multipart/form-data`
/// part with the given `name` and optional `filename`. The output mirrors what
/// `multipartkit/form.add_field` and `add_file` emit:
///
/// - ASCII-safe filenames use the legacy `filename="..."` form.
/// - Filenames with non-ASCII bytes additionally emit the RFC 5987
///   `filename*=UTF-8''<percent-encoded>` form (with an ASCII fallback in
///   the legacy slot).
///
/// Inputs are NOT sanitised here — callers are expected to either sanitise
/// (`form.gleam`) or reject (`part.gleam`) CR / LF / NUL bytes before
/// reaching this builder.
pub fn build_form_data_value(name: String, filename: Option(String)) -> String {
  let base = "form-data; name=" <> quote(name)
  case filename {
    None -> base
    Some(fname) -> base <> filename_disposition_params(fname)
  }
}

/// Strip CR, LF, and NUL from `value`. Used by `multipartkit/form` to
/// silently neutralise header injection in any value that ends up on a
/// header line. `multipartkit/part.new/5` does NOT use this — it rejects
/// these bytes outright.
pub fn sanitize_value(value: String) -> String {
  value
  |> string.replace(each: "\r\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\u{0000}", with: "")
}

/// True iff `value` contains no CR, LF, or NUL bytes — the bytes that
/// would split a header value into multiple wire lines.
pub fn has_header_breaking_bytes(value: String) -> Bool {
  string.contains(value, "\r")
  || string.contains(value, "\n")
  || string.contains(value, "\u{0000}")
}

fn filename_disposition_params(filename: String) -> String {
  case is_ascii_safe(filename) {
    True -> "; filename=" <> quote(filename)
    False ->
      "; filename="
      <> quote(ascii_fallback(filename))
      <> "; filename*=UTF-8''"
      <> percent_encode_rfc5987(filename)
  }
}

fn is_ascii_safe(s: String) -> Bool {
  is_ascii_safe_loop(bit_array.from_string(s))
}

fn is_ascii_safe_loop(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<b, rest:bytes>> ->
      case b == 0x09 || { b >= 0x20 && b <= 0x7E } {
        True -> is_ascii_safe_loop(rest)
        False -> False
      }
    _ -> False
  }
}

fn ascii_fallback(s: String) -> String {
  ascii_fallback_loop(string.to_graphemes(s), "")
}

fn ascii_fallback_loop(remaining: List(String), acc: String) -> String {
  case remaining {
    [] -> acc
    [grapheme, ..rest] ->
      case is_ascii_safe(grapheme) {
        True -> ascii_fallback_loop(rest, acc <> grapheme)
        False -> ascii_fallback_loop(rest, acc <> "_")
      }
  }
}

fn percent_encode_rfc5987(s: String) -> String {
  percent_encode_loop(bit_array.from_string(s), "")
}

fn percent_encode_loop(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<>> -> acc
    <<b, rest:bytes>> -> {
      let chunk = case is_attr_char(b) {
        False -> percent_byte(b)
        True -> bit_array.to_string(<<b>>) |> result.unwrap(percent_byte(b))
      }
      percent_encode_loop(rest, acc <> chunk)
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
  "%" <> hex_digit(b / 16) <> hex_digit(b % 16)
}

fn hex_digit(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "A"
    11 -> "B"
    12 -> "C"
    13 -> "D"
    14 -> "E"
    15 -> "F"
    _ -> int.to_string(n)
  }
}

fn quote(value: String) -> String {
  "\"" <> escape_quoted(value, "") <> "\""
}

fn escape_quoted(remaining: String, acc: String) -> String {
  case string.pop_grapheme(remaining) {
    Error(Nil) -> acc
    Ok(#("\\", rest)) -> escape_quoted(rest, acc <> "\\\\")
    Ok(#("\"", rest)) -> escape_quoted(rest, acc <> "\\\"")
    Ok(#(other, rest)) -> escape_quoted(rest, acc <> other)
  }
}
