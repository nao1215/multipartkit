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
