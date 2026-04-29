//// Internal: header-block parsing for one multipart part.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import multipartkit/content_disposition
import multipartkit/error.{
  type MultipartError, InvalidContentDisposition, InvalidHeader,
}
import multipartkit/internal/text

/// Internal: split a header block (CRLF/LF terminated lines) into a list of
/// `#(name, value)` pairs. Folded headers are rejected with
/// `Error(InvalidHeader)`.
pub fn parse_block(
  block: BitArray,
) -> Result(List(#(String, String)), MultipartError) {
  case bit_array.to_string(block) {
    Error(_) -> Error(InvalidHeader(""))
    Ok(text_block) -> {
      let normalized = string.replace(text_block, each: "\r\n", with: "\n")
      let lines = string.split(normalized, on: "\n")
      let lines = drop_trailing_empty(lines)
      parse_lines(lines, [])
    }
  }
}

fn drop_trailing_empty(lines: List(String)) -> List(String) {
  case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
}

fn parse_lines(
  lines: List(String),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), MultipartError) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] ->
      case parse_line(line) {
        Error(err) -> Error(err)
        Ok(entry) -> parse_lines(rest, [entry, ..acc])
      }
  }
}

fn parse_line(line: String) -> Result(#(String, String), MultipartError) {
  case string.starts_with(line, " ") || string.starts_with(line, "\t") {
    True -> Error(InvalidHeader(line))
    False ->
      case string.split_once(line, on: ":") {
        Error(_) -> Error(InvalidHeader(line))
        Ok(#(name, value)) ->
          case name {
            "" -> Error(InvalidHeader(line))
            _ -> Ok(#(name, trim_ows(value)))
          }
      }
  }
}

fn trim_ows(value: String) -> String {
  let leading_trimmed = text.skip_ows(value)
  trim_trailing_ows(leading_trimmed)
}

fn trim_trailing_ows(value: String) -> String {
  case string.ends_with(value, " ") || string.ends_with(value, "\t") {
    False -> value
    True ->
      case string.length(value) {
        0 -> value
        n -> trim_trailing_ows(string.slice(value, 0, n - 1))
      }
  }
}

/// Internal: derived metadata from a header block — the convenience cache for
/// `Part.name`, `Part.filename`, and `Part.content_type`.
pub type DerivedMeta {
  DerivedMeta(
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
  )
}

/// Internal: extract `name` / `filename` / `content_type` from a parsed
/// header list.
pub fn derive_meta(
  headers: List(#(String, String)),
) -> Result(DerivedMeta, MultipartError) {
  let cd = first_header_ci(headers, "content-disposition")
  let ct = first_header_ci(headers, "content-type")
  case cd {
    None -> Ok(DerivedMeta(name: None, filename: None, content_type: ct))
    Some(value) ->
      case content_disposition.parse(value) {
        Error(_) -> Error(InvalidContentDisposition(value))
        Ok(parsed) -> {
          // Per spec §"Field & File Detection", `name` and `filename`
          // convenience fields are populated only for `form-data`
          // disposition. Other dispositions (e.g. `attachment`) are still
          // surfaced with their raw headers but must not be picked up by
          // query helpers.
          let #(name, filename) = case parsed.disposition {
            "form-data" -> #(parsed.name, parsed.filename)
            _ -> #(None, None)
          }
          Ok(DerivedMeta(name: name, filename: filename, content_type: ct))
        }
      }
  }
}

fn first_header_ci(
  headers: List(#(String, String)),
  name: String,
) -> Option(String) {
  case headers {
    [] -> None
    [#(k, v), ..rest] ->
      case text.equals_ci(k, name) {
        True -> Some(v)
        False -> first_header_ci(rest, name)
      }
  }
}
