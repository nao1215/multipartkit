//// Internal: shared text-grammar primitives used by the Content-Type and
//// Content-Disposition parsers.
////
//// These helpers operate on `String` values (which are UTF-8 in Gleam) but
//// only ever inspect ASCII bytes in this library. Non-ASCII content inside
//// header values is preserved verbatim by quoted-string handling.

import gleam/list
import gleam/string

/// Internal: Skip leading optional whitespace (spaces and tabs) per RFC 7230.
pub fn skip_ows(input: String) -> String {
  case string.pop_grapheme(input) {
    Ok(#(" ", rest)) -> skip_ows(rest)
    Ok(#("\t", rest)) -> skip_ows(rest)
    _ -> input
  }
}

/// Internal: Read a `token` (RFC 7230) from the head of `input` and return
/// `#(token, rest)`. The token is empty if the head does not start with a
/// token char.
pub fn read_token(input: String) -> #(String, String) {
  read_token_loop(input, "")
}

fn read_token_loop(input: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(input) {
    Ok(#(grapheme, rest)) ->
      case is_token_char(grapheme) {
        True -> read_token_loop(rest, acc <> grapheme)
        False -> #(acc, input)
      }
    Error(Nil) -> #(acc, input)
  }
}

fn is_token_char(grapheme: String) -> Bool {
  case grapheme {
    "!" | "#" | "$" | "%" | "&" | "'" | "*" | "+" | "-" | "." -> True
    "^" | "_" | "`" | "|" | "~" -> True
    other -> is_alnum(other)
  }
}

fn is_alnum(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" -> True
    "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" -> True
    "u" | "v" | "w" | "x" | "y" | "z" -> True
    "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J" -> True
    "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" -> True
    "U" | "V" | "W" | "X" | "Y" | "Z" -> True
    _ -> False
  }
}

/// Internal: Read a quoted-string per RFC 7230 §3.2.6 from the head of
/// `input`. The opening `"` must be the first character; the result strips
/// the outer quotes and resolves backslash escapes.
///
/// Returns `Error(Nil)` if the input does not start with `"`, or if the
/// quoted-string is unterminated.
pub fn read_quoted_string(input: String) -> Result(#(String, String), Nil) {
  case string.pop_grapheme(input) {
    Ok(#("\"", rest)) -> read_quoted_loop(rest, "")
    _ -> Error(Nil)
  }
}

fn read_quoted_loop(
  input: String,
  acc: String,
) -> Result(#(String, String), Nil) {
  case string.pop_grapheme(input) {
    Error(_) -> Error(Nil)
    Ok(#("\"", rest)) -> Ok(#(acc, rest))
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Error(_) -> Error(Nil)
        Ok(#(escaped, after)) -> read_quoted_loop(after, acc <> escaped)
      }
    Ok(#(grapheme, rest)) -> read_quoted_loop(rest, acc <> grapheme)
  }
}

/// Internal: Read either a token or a quoted-string from the head of
/// `input`. Returns `#(value, rest)` with `value` being the decoded text.
pub fn read_token_or_quoted(input: String) -> Result(#(String, String), Nil) {
  case string.starts_with(input, "\"") {
    True -> read_quoted_string(input)
    False -> {
      let #(token, rest) = read_token(input)
      case token {
        "" -> Error(Nil)
        _ -> Ok(#(token, rest))
      }
    }
  }
}

/// Internal: Fault categories returned by `read_token_or_quoted_strict`.
///
/// - `QuotedSyntax`: the quoted-string is malformed in a way that is
///   not a quoted-pair grammar violation (e.g. unterminated, missing
///   opening quote, or an empty token where one was expected).
/// - `QuotedPairInvalid`: the input was otherwise a well-formed
///   quoted-string but contained a `\X` escape whose `X` falls outside
///   the RFC 7230 §3.2.6 `quoted-pair` grammar
///   (`HTAB / SP / VCHAR / obs-text`).
pub type QuotedFault {
  QuotedSyntax
  QuotedPairInvalid
}

/// Internal: Like `read_token_or_quoted`, but enforces RFC 7230 §3.2.6
/// strictly inside quoted-strings: the second character of a
/// `quoted-pair` (`\X`) MUST be `HTAB`, `SP`, a `VCHAR` (`%x21-7E`),
/// or `obs-text` (`%x80-FF`). Any other byte (NUL, CR, LF, other ASCII
/// control bytes, or DEL) results in `Error(QuotedPairInvalid)`.
pub fn read_token_or_quoted_strict(
  input: String,
) -> Result(#(String, String), QuotedFault) {
  case string.starts_with(input, "\"") {
    True -> read_quoted_string_strict(input)
    False -> {
      let #(token, rest) = read_token(input)
      case token {
        "" -> Error(QuotedSyntax)
        _ -> Ok(#(token, rest))
      }
    }
  }
}

fn read_quoted_string_strict(
  input: String,
) -> Result(#(String, String), QuotedFault) {
  case string.pop_grapheme(input) {
    Ok(#("\"", rest)) -> read_quoted_loop_strict(rest, "")
    _ -> Error(QuotedSyntax)
  }
}

fn read_quoted_loop_strict(
  input: String,
  acc: String,
) -> Result(#(String, String), QuotedFault) {
  case string.pop_grapheme(input) {
    Error(_) -> Error(QuotedSyntax)
    Ok(#("\"", rest)) -> Ok(#(acc, rest))
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Error(_) -> Error(QuotedSyntax)
        Ok(#(escaped, after)) ->
          case is_valid_quoted_pair_second_char(escaped) {
            True -> read_quoted_loop_strict(after, acc <> escaped)
            False -> Error(QuotedPairInvalid)
          }
      }
    Ok(#(grapheme, rest)) -> read_quoted_loop_strict(rest, acc <> grapheme)
  }
}

/// Internal: RFC 7230 §3.2.6 — the second character of a quoted-pair
/// must be `HTAB / SP / VCHAR / obs-text`. `HTAB` is `%x09`, `SP` is
/// `%x20`, `VCHAR` is `%x21-7E`, `obs-text` is `%x80-FF`. Excluded
/// here are `NUL` (`%x00`), other `%x01-08`, `LF` (`%x0A`), `CR`
/// (`%x0D`), the remaining `%x0B-1F` control bytes, and `DEL`
/// (`%x7F`). Non-ASCII graphemes (any code point ≥ U+0080) are
/// permitted as `obs-text`.
fn is_valid_quoted_pair_second_char(grapheme: String) -> Bool {
  case grapheme {
    "\t" -> True
    " " -> True
    "\u{0000}" -> False
    "\u{0001}" -> False
    "\u{0002}" -> False
    "\u{0003}" -> False
    "\u{0004}" -> False
    "\u{0005}" -> False
    "\u{0006}" -> False
    "\u{0007}" -> False
    "\u{0008}" -> False
    "\n" -> False
    "\u{000B}" -> False
    "\u{000C}" -> False
    "\r" -> False
    "\u{000E}" -> False
    "\u{000F}" -> False
    "\u{0010}" -> False
    "\u{0011}" -> False
    "\u{0012}" -> False
    "\u{0013}" -> False
    "\u{0014}" -> False
    "\u{0015}" -> False
    "\u{0016}" -> False
    "\u{0017}" -> False
    "\u{0018}" -> False
    "\u{0019}" -> False
    "\u{001A}" -> False
    "\u{001B}" -> False
    "\u{001C}" -> False
    "\u{001D}" -> False
    "\u{001E}" -> False
    "\u{001F}" -> False
    "\u{007F}" -> False
    _ -> True
  }
}

/// Internal: Lowercase ASCII A-Z; preserve all other code points. Used in
/// places where we must avoid Unicode case-folding (e.g., header names per
/// RFC 7230).
pub fn ascii_lowercase(input: String) -> String {
  string.to_graphemes(input)
  |> list.map(fold_grapheme_ascii)
  |> string.concat
}

fn fold_grapheme_ascii(grapheme: String) -> String {
  case grapheme {
    "A" -> "a"
    "B" -> "b"
    "C" -> "c"
    "D" -> "d"
    "E" -> "e"
    "F" -> "f"
    "G" -> "g"
    "H" -> "h"
    "I" -> "i"
    "J" -> "j"
    "K" -> "k"
    "L" -> "l"
    "M" -> "m"
    "N" -> "n"
    "O" -> "o"
    "P" -> "p"
    "Q" -> "q"
    "R" -> "r"
    "S" -> "s"
    "T" -> "t"
    "U" -> "u"
    "V" -> "v"
    "W" -> "w"
    "X" -> "x"
    "Y" -> "y"
    "Z" -> "z"
    other -> other
  }
}

/// Internal: ASCII case-insensitive equality.
pub fn equals_ci(a: String, b: String) -> Bool {
  ascii_lowercase(a) == ascii_lowercase(b)
}
