//// Internal: reading and writing the header block of one part.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import multipartkit/internal/text

/// Internal: A header line that could not be read, or `""` when the block
/// is not UTF-8.
pub type InvalidLine {
  InvalidLine(line: String)
}

/// Internal: Split a header block (CRLF or LF terminated lines) into
/// `#(name, value)` pairs. Fails on the first line that is folded, or has no
/// `:` or an empty name.
pub fn parse_block(
  block: BitArray,
) -> Result(List(#(String, String)), InvalidLine) {
  use text_block <- result.try(
    bit_array.to_string(block) |> result.replace_error(InvalidLine("")),
  )
  text_block
  |> string.replace(each: "\r\n", with: "\n")
  |> string.split(on: "\n")
  |> drop_trailing_empty
  |> list.try_map(parse_line)
}

fn drop_trailing_empty(lines: List(String)) -> List(String) {
  case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
}

fn parse_line(line: String) -> Result(#(String, String), InvalidLine) {
  case line, string.split_once(line, on: ":") {
    " " <> _, _ | "\t" <> _, _ -> Error(InvalidLine(line))
    _, Ok(#(name, value)) if name != "" -> Ok(#(name, trim_ows(value)))
    _, _ -> Error(InvalidLine(line))
  }
}

/// Internal: Strip spaces and horizontal tabs (RFC 7230 §3.2.4 OWS) from
/// both ends of a header value. `string.trim` would also strip Unicode
/// whitespace.
pub fn trim_ows(value: String) -> String {
  value |> text.skip_ows |> drop_trailing_ows
}

fn drop_trailing_ows(value: String) -> String {
  use <- bool.guard(
    when: !string.ends_with(value, " ") && !string.ends_with(value, "\t"),
    return: value,
  )
  drop_trailing_ows(string.drop_end(value, 1))
}

/// Internal: Write headers as `name: value` lines, each ending in CRLF.
pub fn encode_block(headers: List(#(String, String))) -> BitArray {
  headers
  |> list.map(fn(entry) {
    <<entry.0:utf8, ": ":utf8, entry.1:utf8, "\r\n":utf8>>
  })
  |> bit_array.concat
}
