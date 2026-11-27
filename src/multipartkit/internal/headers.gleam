//// Internal: reading and writing the header block of one part.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import multipartkit/internal/bytes
import multipartkit/internal/text

/// Internal: Split a header block (CRLF or LF terminated lines) into
/// `#(name, value)` pairs, with the values trimmed.
///
/// A line that starts with a space or tab continues the one before it and
/// is joined to it without the line break (RFC 5322 §2.2.3). Fails with
/// `invalid(line)` for the first line that has no `:`, has a name that
/// `is_valid_name` rejects, holds CR or NUL, or continues a line that does
/// not exist, or is not UTF-8. A line that is not UTF-8 is passed to
/// `invalid` with each bad byte sequence replaced by U+FFFD. The caller
/// passes its own error constructor, so this module needs no error type of
/// its own.
pub fn parse_block(
  block: BitArray,
  invalid: fn(String) -> error,
) -> Result(List(#(String, String)), error) {
  // Split on bytes: on Erlang `string.split` keeps a CR LF pair together as
  // one grapheme, so a bare CR before a CR LF would hide the line break.
  split_lines(block, 0, [])
  |> list.try_fold([], fn(headers, raw) {
    case bit_array.to_string(raw) {
      Error(Nil) -> Error(invalid(replace_invalid_utf8(raw, [])))
      Ok(line) ->
        case add_line(headers, line) {
          Ok(headers) -> Ok(headers)
          Error(Nil) -> Error(invalid(line))
        }
    }
  })
  |> result.map(fn(headers) {
    list.reverse(headers)
    |> list.map(fn(header) { #(header.0, trim_ows(header.1)) })
  })
}

fn split_lines(
  block: BitArray,
  from: Int,
  lines: List(BitArray),
) -> List(BitArray) {
  case bytes.find_index(block, <<"\n":utf8>>, from) {
    Error(Nil) ->
      case bytes.drop(block, from) {
        <<>> -> list.reverse(lines)
        last -> list.reverse([last, ..lines])
      }
    Ok(at) -> {
      let line = bytes.slice_or_empty(block, from, at - from)
      let line = case bytes.ends_with_cr(line) {
        True -> bytes.slice_or_empty(line, 0, bit_array.byte_size(line) - 1)
        False -> line
      }
      split_lines(block, at + 1, [line, ..lines])
    }
  }
}

/// Decode `line` as UTF-8, replacing each maximal invalid subpart with
/// U+FFFD as the WHATWG decoder and Unicode §3.9 do.
fn replace_invalid_utf8(line: BitArray, chunks: List(BitArray)) -> String {
  case line {
    <<lead, rest:bytes>> -> {
      let #(size, valid) = sequence(lead, rest)
      let chunk = case valid {
        True -> bytes.slice_or_empty(line, 0, size)
        False -> <<"\u{FFFD}":utf8>>
      }
      replace_invalid_utf8(bytes.drop(line, size), [chunk, ..chunks])
    }
    _ ->
      list.reverse(chunks)
      |> bit_array.concat
      |> bit_array.to_string
      |> result.unwrap("")
  }
}

/// The length of the sequence that starts with `lead`, and whether it is
/// complete. An incomplete one covers the lead byte and the continuation
/// bytes that could still follow it.
fn sequence(lead: Int, rest: BitArray) -> #(Int, Bool) {
  case lead {
    _ if lead < 0x80 -> #(1, True)
    _ if lead >= 0xC2 && lead <= 0xDF -> continuation(rest, 1, 0x80, 0xBF, 1)
    0xE0 -> continuation(rest, 2, 0xA0, 0xBF, 1)
    0xED -> continuation(rest, 2, 0x80, 0x9F, 1)
    _ if lead >= 0xE1 && lead <= 0xEF -> continuation(rest, 2, 0x80, 0xBF, 1)
    0xF0 -> continuation(rest, 3, 0x90, 0xBF, 1)
    0xF4 -> continuation(rest, 3, 0x80, 0x8F, 1)
    _ if lead >= 0xF1 && lead <= 0xF3 -> continuation(rest, 3, 0x80, 0xBF, 1)
    _ -> #(1, False)
  }
}

/// Take up to `needed` continuation bytes from `rest`, the first in
/// `low..high` and the others in `0x80..0xBF`. `size` counts the bytes
/// taken so far, starting with the lead byte.
fn continuation(
  rest: BitArray,
  needed: Int,
  low: Int,
  high: Int,
  size: Int,
) -> #(Int, Bool) {
  case needed, rest {
    0, _ -> #(size, True)
    _, <<byte, tail:bytes>> if byte >= low && byte <= high ->
      continuation(tail, needed - 1, 0x80, 0xBF, size + 1)
    _, _ -> #(size, False)
  }
}

fn add_line(
  headers: List(#(String, String)),
  line: String,
) -> Result(List(#(String, String)), Nil) {
  use <- bool.guard(
    when: string.contains(line, "\r") || string.contains(line, "\u{0000}"),
    return: Error(Nil),
  )
  case line, headers {
    " " <> _, [#(name, value), ..rest] | "\t" <> _, [#(name, value), ..rest] ->
      Ok([#(name, value <> line), ..rest])
    " " <> _, [] | "\t" <> _, [] -> Error(Nil)
    _, _ ->
      case string.split_once(line, on: ":") {
        Ok(#(name, value)) ->
          case is_valid_name(name) {
            True -> Ok([#(name, value), ..headers])
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Internal: True when `name` is a valid header field name: one or more
/// printable ASCII characters other than `:` (RFC 5322 §3.6.8 `ftext`), so
/// no spaces, tabs or control characters.
pub fn is_valid_name(name: String) -> Bool {
  name != "" && all_ftext(bit_array.from_string(name))
}

fn all_ftext(name: BitArray) -> Bool {
  case name {
    <<>> -> True
    <<byte, rest:bytes>> ->
      byte >= 33 && byte <= 126 && byte != 58 && all_ftext(rest)
    _ -> False
  }
}

/// Internal: Strip spaces and horizontal tabs (RFC 7230 §3.2.4 OWS) from
/// both ends of a header value. `string.trim` would also strip Unicode
/// whitespace.
pub fn trim_ows(value: String) -> String {
  // Reversing keeps this linear, and needs no recursion that is not a tail
  // call on JavaScript.
  value |> text.skip_ows |> string.reverse |> text.skip_ows |> string.reverse
}

/// Internal: Write headers as `name: value` lines, each ending in CRLF.
pub fn encode_block(headers: List(#(String, String))) -> BitArray {
  headers
  |> list.map(fn(entry) {
    <<entry.0:utf8, ": ":utf8, entry.1:utf8, "\r\n":utf8>>
  })
  |> bit_array.concat
}
