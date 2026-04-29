//// Internal: BitArray scanning primitives.
////
//// These helpers are not part of the public API and may change in any
//// release. They live here so the full-body and streaming parsers can share
//// the same boundary-scan logic.

import gleam/bit_array
import gleam/result

/// Internal: Search `haystack` for the first occurrence of `needle` starting
/// at byte offset `from`, scanning byte-by-byte. Returns the offset of the
/// first match, or `Error(Nil)` if no match exists.
///
/// This is an O(n*m) naive scan. The patterns we use (boundary tokens up to
/// 70 bytes per RFC 2046) make this acceptable for v0.1.0.
pub fn find_index(
  haystack: BitArray,
  needle: BitArray,
  from: Int,
) -> Result(Int, Nil) {
  let needle_len = bit_array.byte_size(needle)
  let haystack_len = bit_array.byte_size(haystack)
  case needle_len {
    0 -> Ok(from)
    _ -> find_index_loop(haystack, needle, from, needle_len, haystack_len)
  }
}

fn find_index_loop(
  haystack: BitArray,
  needle: BitArray,
  from: Int,
  needle_len: Int,
  haystack_len: Int,
) -> Result(Int, Nil) {
  case from + needle_len > haystack_len {
    True -> Error(Nil)
    False ->
      case bit_array.slice(haystack, from, needle_len) {
        Ok(window) ->
          case window == needle {
            True -> Ok(from)
            False ->
              find_index_loop(
                haystack,
                needle,
                from + 1,
                needle_len,
                haystack_len,
              )
          }
        Error(_) -> Error(Nil)
      }
  }
}

/// Internal: Slice a sub-range out of `buf` and return `<<>>` on out-of-range
/// rather than `Result(_, Nil)`. Callers must validate ranges separately if
/// they need to distinguish empty-by-design from empty-by-out-of-range.
pub fn slice_or_empty(buf: BitArray, at: Int, length: Int) -> BitArray {
  result.unwrap(bit_array.slice(buf, at, length), <<>>)
}

/// Internal: Return the slice of `buf` from byte offset `from` to the end.
pub fn drop(buf: BitArray, from: Int) -> BitArray {
  let total = bit_array.byte_size(buf)
  case from >= total {
    True -> <<>>
    False -> slice_or_empty(buf, from, total - from)
  }
}

/// Internal: Locate the blank line that terminates a header block inside
/// `buf` starting at line offset `from`.
///
/// The blank line is recognised at any line start when the line itself is
/// empty (i.e. begins immediately with `\r\n` or `\n`). `from` is treated as
/// a line start.
///
/// Returns `#(blank_line_offset, body_start_offset)` where:
///
/// - `blank_line_offset` is the offset of the first byte of the blank line
///   itself (same as the first byte of its line terminator).
/// - `body_start_offset` is the offset of the first byte after the blank
///   line terminator.
///
/// Returns `Error(Nil)` if the buffer does not contain a complete blank line
/// after `from`.
pub fn find_blank_line(buf: BitArray, from: Int) -> Result(#(Int, Int), Nil) {
  let total = bit_array.byte_size(buf)
  find_blank_line_loop(buf, from, total)
}

fn find_blank_line_loop(
  buf: BitArray,
  at: Int,
  total: Int,
) -> Result(#(Int, Int), Nil) {
  case at >= total {
    True -> Error(Nil)
    False ->
      case bit_array.slice(buf, at, 2) {
        Ok(<<"\r\n":utf8>>) -> Ok(#(at, at + 2))
        Ok(<<10, _>>) -> Ok(#(at, at + 1))
        _ ->
          case bit_array.slice(buf, at, 1) {
            Ok(<<10>>) -> Ok(#(at, at + 1))
            _ ->
              case next_line_offset(buf, at, total) {
                Error(_) -> Error(Nil)
                Ok(next) -> find_blank_line_loop(buf, next, total)
              }
          }
      }
  }
}

fn next_line_offset(buf: BitArray, from: Int, total: Int) -> Result(Int, Nil) {
  case from >= total {
    True -> Error(Nil)
    False ->
      case bit_array.slice(buf, from, 2) {
        Ok(<<"\r\n":utf8>>) -> Ok(from + 2)
        Ok(<<10, _>>) -> Ok(from + 1)
        _ ->
          case bit_array.slice(buf, from, 1) {
            Ok(<<10>>) -> Ok(from + 1)
            _ -> next_line_offset(buf, from + 1, total)
          }
      }
  }
}

/// Internal: Return `True` when two ASCII byte sequences are equal modulo
/// case (A-Z mapped to a-z). Non-ASCII bytes compare for exact equality.
pub fn equals_ascii_ci(a: BitArray, b: BitArray) -> Bool {
  case a, b {
    <<>>, <<>> -> True
    <<x, ax:bytes>>, <<y, by:bytes>> ->
      case fold_ascii(x) == fold_ascii(y) {
        True -> equals_ascii_ci(ax, by)
        False -> False
      }
    _, _ -> False
  }
}

fn fold_ascii(byte: Int) -> Int {
  case byte >= 0x41 && byte <= 0x5A {
    True -> byte + 32
    False -> byte
  }
}
