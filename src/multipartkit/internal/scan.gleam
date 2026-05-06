//// Internal: boundary delimiter scanner shared by the full-body and
//// streaming parsers.

import gleam/bit_array
import multipartkit/internal/bytes

/// Internal: kind of delimiter line that was matched.
pub type DelimKind {
  /// `--boundary` followed by CRLF or LF.
  Delimiter
  /// `--boundary--` (closing delimiter).
  Closing
}

/// Internal: result of scanning for the next boundary delimiter starting at
/// byte offset `from`.
pub type ScanOutcome {
  /// `body_end_excl` is the offset of the first byte of the line-ending that
  /// precedes the delimiter (or `from` when the delimiter sits at the start
  /// of the buffer with no preceding line-ending).
  ///
  /// `after_delim_offset` is the offset just past the delimiter line —
  /// either past the trailing CRLF/LF for `Delimiter`, or past the closing
  /// `--` (and optional trailing CRLF/LF) for `Closing`.
  Found(body_end_excl: Int, kind: DelimKind, after_delim_offset: Int)
  /// The buffer does not yet contain a complete delimiter; more input is
  /// needed (streaming case) or the input ended unexpectedly (full-body case).
  Incomplete
}

/// Internal: build the `--boundary` byte pattern as a BitArray.
pub fn dash_pattern(boundary: String) -> BitArray {
  bit_array.append(<<"--":utf8>>, bit_array.from_string(boundary))
}

/// Internal: scan `buf` starting at `from` for the next valid boundary
/// delimiter line.
pub fn find_delimiter(
  buf: BitArray,
  pattern: BitArray,
  from: Int,
) -> ScanOutcome {
  let total = bit_array.byte_size(buf)
  scan_loop(buf, pattern, from, total)
}

fn scan_loop(
  buf: BitArray,
  pattern: BitArray,
  from: Int,
  total: Int,
) -> ScanOutcome {
  case bytes.find_index(buf, pattern, from) {
    Error(Nil) -> Incomplete
    Ok(p) ->
      case is_at_line_start(buf, p) {
        False -> scan_loop(buf, pattern, p + 1, total)
        True -> {
          let body_end_excl = body_end_for(buf, p)
          let after_pattern = p + bit_array.byte_size(pattern)
          case classify_after(buf, after_pattern, total) {
            ClassDelimiter(after) -> Found(body_end_excl, Delimiter, after)
            ClassClosing(after) -> Found(body_end_excl, Closing, after)
            ClassInvalid -> scan_loop(buf, pattern, p + 1, total)
            ClassIncomplete -> Incomplete
          }
        }
      }
  }
}

fn is_at_line_start(buf: BitArray, p: Int) -> Bool {
  case p {
    0 -> True
    _ ->
      case bit_array.slice(buf, p - 1, 1) {
        Ok(<<10>>) -> True
        _ -> False
      }
  }
}

fn body_end_for(buf: BitArray, p: Int) -> Int {
  case p {
    0 -> 0
    _ -> {
      case p >= 2 && bit_array.slice(buf, p - 2, 2) == Ok(<<"\r\n":utf8>>) {
        True -> p - 2
        False ->
          case bit_array.slice(buf, p - 1, 1) {
            Ok(<<10>>) -> p - 1
            _ -> p
          }
      }
    }
  }
}

type AfterClass {
  ClassDelimiter(after: Int)
  ClassClosing(after: Int)
  ClassInvalid
  ClassIncomplete
}

fn classify_after(buf: BitArray, at: Int, total: Int) -> AfterClass {
  case at >= total {
    True -> ClassIncomplete
    False -> {
      // RFC 2046 §5.1.1 transport-padding := *LWSP-char between the
      // boundary token and the line ending (or `--` for the closing
      // delimiter). Spaces and tabs only.
      let after_padding = skip_lwsp(buf, at, total)
      case bit_array.slice(buf, after_padding, 2) {
        Ok(<<"--":utf8>>) ->
          ClassClosing(consume_closing_tail(buf, after_padding + 2, total))
        Ok(<<"\r\n":utf8>>) -> ClassDelimiter(after_padding + 2)
        Ok(<<10, _>>) -> ClassDelimiter(after_padding + 1)
        _ ->
          case bit_array.slice(buf, after_padding, 1) {
            Ok(<<10>>) -> ClassDelimiter(after_padding + 1)
            Ok(_) -> {
              case after_padding + 2 > total {
                True -> ClassIncomplete
                False -> ClassInvalid
              }
            }
            Error(Nil) -> {
              case after_padding >= total {
                True -> ClassIncomplete
                False -> ClassInvalid
              }
            }
          }
      }
    }
  }
}

fn consume_closing_tail(buf: BitArray, at: Int, total: Int) -> Int {
  let after_padding = skip_lwsp(buf, at, total)
  case after_padding >= total {
    True -> after_padding
    False ->
      case bit_array.slice(buf, after_padding, 2) {
        Ok(<<"\r\n":utf8>>) -> after_padding + 2
        _ ->
          case bit_array.slice(buf, after_padding, 1) {
            Ok(<<10>>) -> after_padding + 1
            _ -> after_padding
          }
      }
  }
}

fn skip_lwsp(buf: BitArray, at: Int, total: Int) -> Int {
  case at >= total {
    True -> at
    False ->
      case bit_array.slice(buf, at, 1) {
        Ok(<<32>>) -> skip_lwsp(buf, at + 1, total)
        Ok(<<9>>) -> skip_lwsp(buf, at + 1, total)
        _ -> at
      }
  }
}
