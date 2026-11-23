//// Internal: boundary delimiter scanner shared by the full-body and
//// streaming parsers.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
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
  /// precedes the delimiter, and never less than `from`. The line-ending
  /// belongs to the delimiter (RFC 2046 §5.1.1), so when it is the blank
  /// line that ended the headers, the body is empty.
  ///
  /// `after_delim_offset` is the offset just past the delimiter line —
  /// either past the trailing CRLF/LF for `Delimiter`, or past the closing
  /// `--` (and optional trailing CRLF/LF) for `Closing`.
  Found(body_end_excl: Int, kind: DelimKind, after_delim_offset: Int)
  /// The buffer does not yet contain a complete delimiter; more input is
  /// needed (streaming case) or the input ended unexpectedly (full-body case).
  ///
  /// `body_until` is the offset before which no delimiter can still start,
  /// whatever bytes come next: every byte before it belongs to the body.
  Incomplete(body_until: Int)
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
  scan_loop(buf, pattern, from, from, total)
}

fn scan_loop(
  buf: BitArray,
  pattern: BitArray,
  start: Int,
  from: Int,
  total: Int,
) -> ScanOutcome {
  case bytes.find_index(buf, pattern, from) {
    // A delimiter that is still to come starts at least `pattern - 1` bytes
    // before the end, after a line ending of up to 2 bytes.
    Error(Nil) ->
      Incomplete(int.max(start, total - bit_array.byte_size(pattern) - 1))
    Ok(p) ->
      case is_at_line_start(buf, p) {
        False -> scan_loop(buf, pattern, start, p + 1, total)
        True -> {
          let body_end_excl = int.max(body_end_for(buf, p), start)
          let after_pattern = p + bit_array.byte_size(pattern)
          case classify_after(buf, after_pattern, total) {
            ClassDelimiter(after) -> Found(body_end_excl, Delimiter, after)
            ClassClosing(after) -> Found(body_end_excl, Closing, after)
            ClassInvalid -> scan_loop(buf, pattern, start, p + 1, total)
            ClassIncomplete -> Incomplete(body_end_excl)
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
  // RFC 2046 §5.1.1: close-delimiter := delimiter "--", then
  // transport-padding := *LWSP-char before the line ending. The `--` comes
  // right after the boundary, and padding only after that.
  case bit_array.slice(buf, at, 2), bit_array.slice(buf, at, 1) {
    _, Error(Nil) -> ClassIncomplete
    Ok(<<"--":utf8>>), _ ->
      ClassClosing(consume_closing_tail(buf, at + 2, total))
    Error(Nil), Ok(<<"-":utf8>>) -> ClassIncomplete
    _, _ -> classify_padded(buf, skip_lwsp(buf, at, total))
  }
}

fn classify_padded(buf: BitArray, at: Int) -> AfterClass {
  case bit_array.slice(buf, at, 2), bit_array.slice(buf, at, 1) {
    Ok(<<"\r\n":utf8>>), _ -> ClassDelimiter(at + 2)
    _, Ok(<<10>>) -> ClassDelimiter(at + 1)
    // A CR at the end may still be followed by LF.
    Error(Nil), Ok(<<13>>) -> ClassIncomplete
    _, Error(Nil) -> ClassIncomplete
    _, _ -> ClassInvalid
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

/// Internal: Check `data` for a line that starts with `pattern`, the
/// dash-boundary that RFC 2046 §5.1.1 forbids at the start of any line in
/// a body part. A line starts after LF, and at offset 0 when `carry` is
/// `Some`.
///
/// `carry` is the start of a line left over from the previous call on the
/// same part, so a chunked body is checked as if it were whole. Returns
/// `Error(Nil)` on a match, otherwise the carry for the next chunk: the
/// last line when it is still a prefix of `pattern`.
pub fn check_line_starts(
  carry: Option(BitArray),
  data: BitArray,
  pattern: BitArray,
) -> Result(Option(BitArray), Nil) {
  let #(data, at_line_start) = case carry {
    Some(<<>>) -> #(data, True)
    Some(start) -> #(<<start:bits, data:bits>>, True)
    None -> #(data, False)
  }
  use <- bool.guard(
    when: { at_line_start && bytes.starts_with(data, pattern) }
      || result.is_ok(bytes.find_index(data, <<"\n":utf8, pattern:bits>>, 0)),
    return: Error(Nil),
  )
  let size = bit_array.byte_size(data)
  let pattern_size = bit_array.byte_size(pattern)
  // Only a last line shorter than the pattern can still grow into it.
  let last_line = case last_newline(data, size - 1, size - pattern_size) {
    Ok(at) -> Ok(bytes.drop(data, at + 1))
    Error(Nil) if at_line_start && size < pattern_size -> Ok(data)
    Error(Nil) -> Error(Nil)
  }
  case last_line {
    Ok(line) ->
      case bytes.starts_with(pattern, line) {
        True -> Ok(Some(line))
        False -> Ok(None)
      }
    Error(Nil) -> Ok(None)
  }
}

fn last_newline(data: BitArray, at: Int, lowest: Int) -> Result(Int, Nil) {
  use <- bool.guard(when: at < 0 || at < lowest, return: Error(Nil))
  case bit_array.slice(data, at, 1) {
    Ok(<<10>>) -> Ok(at)
    _ -> last_newline(data, at - 1, lowest)
  }
}
