import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import multipartkit/error.{
  type MultipartError, InvalidContentDisposition, InvalidQuotedPair,
}
import multipartkit/internal/text.{QuotedPairInvalid, QuotedSyntax}

/// A parsed `Content-Disposition` header value.
///
/// Opaque — inspect through `disposition/1`, `name/1`, `filename/1`, and
/// `params/1`. The internal layout may grow more fields (a parsed
/// `creation-date`, etc.) without breaking external pattern matches.
///
/// Semantics of each accessor:
///
/// - `disposition/1` is lowercased (`"form-data"`, `"attachment"`, ...).
/// - `name/1` and `filename/1` are convenience accessors decoded from
///   RFC 5987 / RFC 8187 `*`-form when present (with the `*`-form taking
///   precedence over the plain form), otherwise from the plain parameter
///   value with surrounding quotes removed and backslash-escapes resolved
///   per RFC 7230 §3.2.6 quoted-string / quoted-pair rules. A `\X`
///   escape whose `X` is outside the `quoted-pair` grammar
///   (`HTAB / SP / VCHAR / obs-text`) — for instance `NUL`, `CR`, `LF`,
///   or any other ASCII control byte — causes `parse` to return
///   `Error(InvalidQuotedPair(original_value))` instead of silently
///   dropping the backslash. This blocks `NUL`-smuggling into the
///   decoded `name` / `filename`.
/// - `params/1` contains every parameter as it appeared in the input
///   including `filename` and `name`, in order. Duplicate parameter names
///   are preserved left-to-right; only the first occurrence wins for the
///   convenience `name`/`filename` fields.
pub opaque type ContentDisposition {
  ContentDisposition(
    disposition: String,
    name: Option(String),
    filename: Option(String),
    params: List(#(String, String)),
  )
}

/// The `disposition` token, lowercased.
pub fn disposition(parsed: ContentDisposition) -> String {
  parsed.disposition
}

/// The decoded `name` parameter, or `None` if absent.
pub fn name(parsed: ContentDisposition) -> Option(String) {
  parsed.name
}

/// The decoded `filename` parameter, or `None` if absent. Honours
/// RFC 5987 / RFC 8187 `*`-form precedence.
pub fn filename(parsed: ContentDisposition) -> Option(String) {
  parsed.filename
}

/// All raw parameters as `(key, value)` pairs in input order. Includes
/// `name` and `filename` (and `*`-form variants) before convenience
/// decoding.
pub fn params(parsed: ContentDisposition) -> List(#(String, String)) {
  parsed.params
}

/// Parse a Content-Disposition header value.
///
/// Returns `Error(InvalidContentDisposition(value))` for unparseable input.
pub fn parse(value: String) -> Result(ContentDisposition, MultipartError) {
  let original = value
  let rest = text.skip_ows(value)
  let #(token, rest_after_token) = text.read_token(rest)
  case token {
    "" -> Error(InvalidContentDisposition(original))
    _ ->
      case parse_params(rest_after_token, [], original) {
        Error(err) -> Error(err)
        Ok(params) -> {
          let disposition = text.ascii_lowercase(token)
          let name_value = pick_convenience(params, "name", original)
          let filename_value = pick_convenience(params, "filename", original)
          case name_value, filename_value {
            Error(err), _ -> Error(err)
            _, Error(err) -> Error(err)
            Ok(name), Ok(filename) ->
              Ok(ContentDisposition(
                disposition: disposition,
                name: name,
                filename: filename,
                params: params,
              ))
          }
        }
      }
  }
}

fn parse_params(
  input: String,
  acc: List(#(String, String)),
  original: String,
) -> Result(List(#(String, String)), MultipartError) {
  let after_ows = text.skip_ows(input)
  case after_ows {
    "" -> Ok(list.reverse(acc))
    _ ->
      case string.pop_grapheme(after_ows) {
        Ok(#(";", rest)) -> parse_one_param(rest, acc, original)
        _ -> Error(InvalidContentDisposition(original))
      }
  }
}

fn parse_one_param(
  rest: String,
  acc: List(#(String, String)),
  original: String,
) -> Result(List(#(String, String)), MultipartError) {
  let inner_rest = text.skip_ows(rest)
  let #(key, after_key) = text.read_token(inner_rest)
  case key {
    "" -> Error(InvalidContentDisposition(original))
    _ ->
      case string.pop_grapheme(after_key) {
        Ok(#("=", value_rest)) ->
          case text.read_token_or_quoted_strict(value_rest) {
            Error(QuotedPairInvalid) -> Error(InvalidQuotedPair(original))
            Error(QuotedSyntax) -> Error(InvalidContentDisposition(original))
            Ok(#(raw_value, tail)) ->
              parse_params(tail, [#(key, raw_value), ..acc], original)
          }
        _ -> Error(InvalidContentDisposition(original))
      }
  }
}

fn pick_convenience(
  params: List(#(String, String)),
  base_name: String,
  original: String,
) -> Result(Option(String), MultipartError) {
  let star = base_name <> "*"
  case find_param_ci(params, star) {
    Some(raw) ->
      case decode_rfc5987(raw) {
        Ok(value) -> Ok(Some(value))
        Error(_) -> Error(InvalidContentDisposition(original))
      }
    None ->
      case find_param_ci(params, base_name) {
        Some(raw) -> Ok(Some(raw))
        None -> Ok(None)
      }
  }
}

fn find_param_ci(params: List(#(String, String)), key: String) -> Option(String) {
  case params {
    [] -> None
    [#(k, v), ..rest] ->
      case text.equals_ci(k, key) {
        True -> Some(v)
        False -> find_param_ci(rest, key)
      }
  }
}

/// Decode a RFC 5987 / 8187 `charset 'lang' value` parameter into a Gleam
/// `String`. Supports UTF-8 and ISO-8859-1.
fn decode_rfc5987(input: String) -> Result(String, Nil) {
  case string.split_once(input, on: "'") {
    Error(_) -> Error(Nil)
    Ok(#(charset, after_first)) ->
      case string.split_once(after_first, on: "'") {
        Error(_) -> Error(Nil)
        Ok(#(_lang, encoded_value)) -> {
          use bytes <- result.try(percent_decode(encoded_value))
          decode_with_charset(charset, bytes)
        }
      }
  }
}

fn decode_with_charset(charset: String, bytes: BitArray) -> Result(String, Nil) {
  let lower = text.ascii_lowercase(charset)
  case lower {
    "utf-8" -> bit_array.to_string(bytes)
    "iso-8859-1" -> Ok(latin1_to_utf8(bytes, ""))
    _ -> Error(Nil)
  }
}

fn latin1_to_utf8(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<>> -> acc
    <<b, rest:bytes>> -> latin1_to_utf8(rest, acc <> code_point_to_string(b))
    _ -> acc
  }
}

fn code_point_to_string(byte: Int) -> String {
  case byte < 0x80 {
    True -> ascii_byte_to_string(byte)
    False -> {
      let high = 0xC0 + { byte / 64 }
      let low = 0x80 + { byte % 64 }
      result.unwrap(bit_array.to_string(<<high, low>>), "")
    }
  }
}

fn ascii_byte_to_string(byte: Int) -> String {
  result.unwrap(bit_array.to_string(<<byte>>), "")
}

fn percent_decode(input: String) -> Result(BitArray, Nil) {
  percent_decode_loop(string.to_graphemes(input), <<>>)
}

fn percent_decode_loop(
  remaining: List(String),
  acc: BitArray,
) -> Result(BitArray, Nil) {
  case remaining {
    [] -> Ok(acc)
    ["%", high, low, ..rest] ->
      case hex_pair(high, low) {
        Error(_) -> Error(Nil)
        Ok(byte) -> percent_decode_loop(rest, <<acc:bits, byte>>)
      }
    ["%", ..] -> Error(Nil)
    [other, ..rest] -> {
      let chunk = bit_array.from_string(other)
      percent_decode_loop(rest, <<acc:bits, chunk:bits>>)
    }
  }
}

fn hex_pair(high: String, low: String) -> Result(Int, Nil) {
  use h <- result.try(hex_digit(high))
  use l <- result.try(hex_digit(low))
  Ok(h * 16 + l)
}

fn hex_digit(grapheme: String) -> Result(Int, Nil) {
  case grapheme {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    "a" | "A" -> Ok(10)
    "b" | "B" -> Ok(11)
    "c" | "C" -> Ok(12)
    "d" | "D" -> Ok(13)
    "e" | "E" -> Ok(14)
    "f" | "F" -> Ok(15)
    _ -> Error(Nil)
  }
}
