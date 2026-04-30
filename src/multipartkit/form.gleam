import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import multipartkit/infer
import multipartkit/part.{type Part}

/// Opaque builder for multipart/form-data messages.
///
/// `Form` is constructed via `new` and accumulated with `add_field` /
/// `add_file` / `add_file_auto` / `unsafe_add_part`. Read it back as
/// `List(Part)` via `parts`. The boundary is generated lazily by
/// `encode_form` and is not part of `Form`'s observable state.
pub opaque type Form {
  Form(reversed_parts: List(Part))
}

/// A new empty form.
pub fn new() -> Form {
  Form(reversed_parts: [])
}

/// Append a text field. `value` is encoded as UTF-8 in the part body. No
/// filename is set.
///
/// Carriage returns, line feeds, and NUL bytes in `name` are silently
/// stripped to prevent header injection. The cached `name` on the resulting
/// `Part` reflects the sanitized value, matching what a parse-after-encode
/// round-trip would produce. Use `unsafe_add_part` if byte-exact
/// preservation is required.
pub fn add_field(form: Form, name: String, value: String) -> Form {
  let safe_name = sanitize_value(name)
  let disposition = #(
    "Content-Disposition",
    "form-data; name=" <> quote(safe_name),
  )
  let new_part =
    part.new(
      headers: [disposition],
      name: Some(safe_name),
      filename: None,
      content_type: None,
      body: <<value:utf8>>,
    )
  push(form, new_part)
}

/// Append a file part with an explicit content type.
///
/// Carriage returns, line feeds, and NUL bytes in `name`, `filename`, and
/// `content_type` are silently stripped to prevent header injection. The
/// cached `name`, `filename`, and `content_type` on the resulting `Part`
/// reflect the sanitized values. Use `unsafe_add_part` if byte-exact
/// preservation is required.
pub fn add_file(
  form: Form,
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Form {
  push(form, build_file_part(name, filename, content_type, body))
}

/// Append a file part using the default (no-op) inferer.
///
/// Equivalent to `add_file_auto_with(form, name, filename, body,
/// infer.default_inferer())`. The default inferer returns `None` from both
/// helpers in v0.1.0, so this falls through to `application/octet-stream`
/// unless you call `add_file_auto_with` with a real inferer.
pub fn add_file_auto(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
) -> Form {
  add_file_auto_with(form, name, filename, body, infer.default_inferer())
}

/// Append a file part, inferring the content type via the supplied
/// `Inferer`.
///
/// Inference precedence:
///
/// 1. `inferer.from_filename(filename)`
/// 2. `inferer.from_bytes(body)`
/// 3. `application/octet-stream`
///
/// The inferred content type is sanitized (CR / LF / NUL stripped) before
/// being written to the header.
pub fn add_file_auto_with(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
  inferer: infer.Inferer,
) -> Form {
  let content_type = case inferer.from_filename(filename) {
    Some(value) -> value
    None ->
      case inferer.from_bytes(body) {
        Some(value) -> value
        None -> "application/octet-stream"
      }
  }
  add_file(form, name, filename, content_type, body)
}

/// Append a pre-built `Part` without validation or normalisation.
///
/// The caller is responsible for keeping `headers`, `name`, `filename`, and
/// `content_type` mutually consistent. Prefer `add_field` / `add_file` /
/// `add_file_auto` for library-maintained consistency.
pub fn unsafe_add_part(form: Form, the_part: Part) -> Form {
  push(form, the_part)
}

/// Read the parts in insertion order.
pub fn parts(form: Form) -> List(Part) {
  list.reverse(form.reversed_parts)
}

fn push(form: Form, the_part: Part) -> Form {
  Form(reversed_parts: [the_part, ..form.reversed_parts])
}

fn build_file_part(
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Part {
  let safe_name = sanitize_value(name)
  let safe_filename = sanitize_value(filename)
  let safe_content_type = sanitize_value(content_type)
  let disposition_header = #(
    "Content-Disposition",
    "form-data; name="
      <> quote(safe_name)
      <> filename_disposition_params(safe_filename),
  )
  let content_type_header = #("Content-Type", safe_content_type)
  part.new(
    headers: [disposition_header, content_type_header],
    name: Some(safe_name),
    filename: Some(safe_filename),
    content_type: Some(safe_content_type),
    body: body,
  )
}

/// Build the `; filename=...` portion of a Content-Disposition header
/// for a file part.
///
/// For ASCII-safe filenames (every code point is printable US-ASCII
/// per RFC 7230 §3.2.4) the legacy `filename="..."` form is sufficient
/// and is emitted unchanged.
///
/// For filenames that contain bytes outside that range, the legacy
/// form would produce a header value that violates RFC 7230 §3.2.4 and
/// is mangled or rejected by strict HTTP intermediaries. We emit BOTH:
///
/// - `filename="<ascii-fallback>"` — non-ASCII code points replaced
///   with `_`. Lets pre-RFC-5987 clients still see a sensible name.
/// - `filename*=UTF-8''<percent-encoded>` — RFC 5987 §3.2.1 / RFC 6266
///   §4.3 form, faithful round-trip for spec-aware parsers.
///
/// RFC 5987 §3.2.2: when both forms are present, the `*=` form takes
/// precedence — multipartkit's own `content_disposition.parse` already
/// honours that ordering, as do all browsers and the major HTTP
/// servers.
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

/// True iff every code point in `s` is printable US-ASCII (0x20-0x7E)
/// or HTAB. Matches the subset of bytes RFC 7230 §3.2.4 admits as
/// header field values.
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

/// Replace every non-ASCII-safe code point in `s` with `_` so the
/// result is safe for use inside a legacy `filename="..."`. Used as
/// the pre-RFC-5987 fallback alongside `filename*=`.
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

/// Percent-encode the UTF-8 byte representation of `s` per RFC 5987
/// §3.2.1 attr-char. Bytes that match the attr-char production
/// (`ALPHA / DIGIT / "!" / "#" / "$" / "&" / "+" / "-" / "." / "^" /
/// "_" / "`" / "|" / "~"`) pass through unencoded; every other byte
/// is emitted as `%HH` with uppercase hex digits.
fn percent_encode_rfc5987(s: String) -> String {
  percent_encode_loop(bit_array.from_string(s), "")
}

fn percent_encode_loop(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<>> -> acc
    <<b, rest:bytes>> -> {
      // attr-char bytes pass through as their literal ASCII character;
      // every other byte (including the high bytes of multi-byte UTF-8
      // sequences) is emitted as `%HH`. `bit_array.to_string` is used
      // for the attr-char branch and falls back to the percent-byte
      // form on any conversion error — every byte for which
      // `is_attr_char` returns True is in the printable US-ASCII range
      // and converts cleanly, so the fallback is purely for type
      // safety.
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

/// Strip CR, LF, and NUL from `value`. Used to neutralise header injection
/// in any value that ends up on a header line — `name`, `filename`, and
/// `content_type`.
fn sanitize_value(value: String) -> String {
  value
  |> string.replace(each: "\r\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\u{0000}", with: "")
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
