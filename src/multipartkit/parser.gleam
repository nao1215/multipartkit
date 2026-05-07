import gleam/bit_array
import gleam/list
import multipartkit/error.{
  type MultipartError, BodyTooLarge, HeaderTooLarge, PartTooLarge, TooManyParts,
  UnexpectedEndOfInput,
}
import multipartkit/header
import multipartkit/internal/bytes
import multipartkit/internal/headers
import multipartkit/internal/scan
import multipartkit/limit.{type Limits}
import multipartkit/part.{type Part}

/// Parse a multipart body using `default_limits()`.
///
/// `content_type` must be the full HTTP Content-Type value, including the
/// `boundary` parameter — for example `multipart/form-data; boundary=abc`.
pub fn parse(
  body: BitArray,
  content_type: String,
) -> Result(List(Part), MultipartError) {
  parse_with_limits(body, content_type, limit.default_limits())
}

/// Parse a multipart body with caller-supplied limits.
pub fn parse_with_limits(
  body: BitArray,
  content_type: String,
  limits: Limits,
) -> Result(List(Part), MultipartError) {
  case header.boundary(content_type) {
    Error(err) -> Error(err)
    Ok(boundary_value) -> {
      let total = bit_array.byte_size(body)
      case total > limit.max_body_bytes(limits) {
        True -> Error(BodyTooLarge(limit.max_body_bytes(limits)))
        False -> {
          let pattern = scan.dash_pattern(boundary_value)
          case scan.find_delimiter(body, pattern, 0) {
            scan.Incomplete -> Error(UnexpectedEndOfInput)
            scan.Found(_body_end, scan.Closing, _after) ->
              // The very first delimiter is the closing one — empty multipart.
              Ok([])
            scan.Found(_body_end, scan.Delimiter, after_first) ->
              parse_loop(body, pattern, after_first, limits, [], 0)
          }
        }
      }
    }
  }
}

fn parse_loop(
  body: BitArray,
  pattern: BitArray,
  cursor: Int,
  limits: Limits,
  acc: List(Part),
  parts_count: Int,
) -> Result(List(Part), MultipartError) {
  case enforce_total(cursor, limits) {
    Error(err) -> Error(err)
    Ok(_) ->
      case bytes.find_blank_line(body, cursor) {
        Error(_) -> Error(UnexpectedEndOfInput)
        Ok(#(blank_at, body_start)) -> {
          let header_block_size = body_start - cursor
          case header_block_size > limit.max_header_bytes(limits) {
            True -> Error(HeaderTooLarge(limit.max_header_bytes(limits)))
            False -> {
              let header_block =
                bytes.slice_or_empty(body, cursor, blank_at - cursor)
              case headers.parse_block(header_block) {
                Error(err) -> Error(err)
                Ok(header_list) ->
                  case headers.derive_meta(header_list) {
                    Error(err) -> Error(err)
                    Ok(meta) ->
                      case scan.find_delimiter(body, pattern, body_start) {
                        scan.Incomplete -> Error(UnexpectedEndOfInput)
                        scan.Found(body_end_excl, kind, after_delim) -> {
                          let body_size = body_end_excl - body_start
                          case body_size > limit.max_part_bytes(limits) {
                            True ->
                              Error(PartTooLarge(limit.max_part_bytes(limits)))
                            False -> {
                              let part_body =
                                bytes.slice_or_empty(
                                  body,
                                  body_start,
                                  body_size,
                                )
                              let new_part =
                                part.unchecked_new(
                                  headers: header_list,
                                  name: meta.name,
                                  filename: meta.filename,
                                  content_type: meta.content_type,
                                  body: part_body,
                                )
                              let new_count = parts_count + 1
                              case new_count > limit.max_parts(limits) {
                                True ->
                                  Error(TooManyParts(limit.max_parts(limits)))
                                False ->
                                  case enforce_total(after_delim, limits) {
                                    Error(err) -> Error(err)
                                    Ok(_) -> {
                                      let acc = [new_part, ..acc]
                                      case kind {
                                        scan.Closing -> Ok(list.reverse(acc))
                                        scan.Delimiter ->
                                          parse_loop(
                                            body,
                                            pattern,
                                            after_delim,
                                            limits,
                                            acc,
                                            new_count,
                                          )
                                      }
                                    }
                                  }
                              }
                            }
                          }
                        }
                      }
                  }
              }
            }
          }
        }
      }
  }
}

fn enforce_total(consumed: Int, limits: Limits) -> Result(Nil, MultipartError) {
  case consumed > limit.max_body_bytes(limits) {
    True -> Error(BodyTooLarge(limit.max_body_bytes(limits)))
    False -> Ok(Nil)
  }
}
