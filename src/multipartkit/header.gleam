import gleam/option.{type Option, None, Some}
import gleam/string
import multipartkit/error.{
  type MultipartError, InvalidBoundary, InvalidContentType, MissingBoundary,
  UnsupportedMediaType,
}
import multipartkit/internal/text

/// Extract the `boundary` parameter from a `Content-Type` header value.
///
/// The error priority documented for `parse` is enforced here:
///
/// 1. `InvalidContentType(value)` — value cannot be parsed as a media type.
/// 2. `UnsupportedMediaType(media_type)` — top-level media type is not
///    `multipart/*`.
/// 3. `MissingBoundary` — the `boundary` parameter is absent.
/// 4. `InvalidBoundary(value)` — present but violates the RFC 2046 grammar.
pub fn boundary(content_type: String) -> Result(String, MultipartError) {
  let original = content_type
  let rest = text.skip_ows(content_type)
  case parse_media_type(rest) {
    Error(_) -> Error(InvalidContentType(original))
    Ok(#(media_type, after_type)) ->
      case is_multipart(media_type) {
        False -> Error(UnsupportedMediaType(media_type))
        True ->
          case scan_for_boundary(after_type, original, None) {
            Error(err) -> Error(err)
            Ok(None) -> Error(MissingBoundary)
            Ok(Some(value)) ->
              case validate_boundary(value) {
                True -> Ok(value)
                False -> Error(InvalidBoundary(value))
              }
          }
      }
  }
}

fn parse_media_type(input: String) -> Result(#(String, String), Nil) {
  let #(type_token, rest) = text.read_token(input)
  case type_token {
    "" -> Error(Nil)
    _ ->
      case string.pop_grapheme(rest) {
        Ok(#("/", rest_after_slash)) -> {
          let #(subtype_token, tail) = text.read_token(rest_after_slash)
          case subtype_token {
            "" -> Error(Nil)
            _ -> Ok(#(type_token <> "/" <> subtype_token, tail))
          }
        }
        _ -> Error(Nil)
      }
  }
}

fn is_multipart(media_type: String) -> Bool {
  let lower = text.ascii_lowercase(media_type)
  string.starts_with(lower, "multipart/")
  && string.length(lower) > string.length("multipart/")
}

fn scan_for_boundary(
  input: String,
  original: String,
  found: Option(String),
) -> Result(Option(String), MultipartError) {
  let after_ows = text.skip_ows(input)
  case after_ows {
    "" -> Ok(found)
    _ ->
      case string.pop_grapheme(after_ows) {
        Ok(#(";", rest)) -> read_parameter(rest, original, found)
        _ -> Error(InvalidContentType(original))
      }
  }
}

fn read_parameter(
  input: String,
  original: String,
  found: Option(String),
) -> Result(Option(String), MultipartError) {
  let after_ows = text.skip_ows(input)
  let #(key, rest) = text.read_token(after_ows)
  case key {
    "" -> Error(InvalidContentType(original))
    _ ->
      case string.pop_grapheme(rest) {
        Ok(#("=", value_rest)) ->
          case text.read_token_or_quoted(value_rest) {
            Error(_) -> Error(InvalidContentType(original))
            Ok(#(raw_value, tail)) -> {
              let next_found = case text.equals_ci(key, "boundary"), found {
                True, None -> Some(raw_value)
                _, _ -> found
              }
              scan_for_boundary(tail, original, next_found)
            }
          }
        _ -> Error(InvalidContentType(original))
      }
  }
}

/// Returns `True` when `value` satisfies the RFC 2046 §5.1.1 `boundary`
/// grammar (1-70 `bchars` ending in a `bcharsnospace`). Used by `boundary/1`
/// on the parse side and by the encoder on the encode side so both ends
/// reject the same set of strings.
pub fn validate_boundary(value: String) -> Bool {
  let length = string.length(value)
  case length >= 1 && length <= 70 {
    False -> False
    True ->
      case string.ends_with(value, " ") {
        True -> False
        False ->
          string.to_graphemes(value)
          |> list_all_bcharsnospace
      }
  }
}

fn list_all_bcharsnospace(graphemes: List(String)) -> Bool {
  case graphemes {
    [] -> True
    [first, ..rest] ->
      case is_bchar(first) {
        True -> list_all_bcharsnospace(rest)
        False -> False
      }
  }
}

fn is_bchar(grapheme: String) -> Bool {
  case grapheme {
    "'" | "(" | ")" | "+" | "_" | "," | "-" | "." -> True
    "/" | ":" | "=" | "?" | " " -> True
    other -> is_bchar_alnum(other)
  }
}

fn is_bchar_alnum(grapheme: String) -> Bool {
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
