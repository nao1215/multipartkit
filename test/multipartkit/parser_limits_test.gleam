import gleam/bit_array
import gleeunit/should
import multipartkit/error.{
  BodyTooLarge, HeaderTooLarge, PartTooLarge, TooManyParts,
}
import multipartkit/limit.{Limits}
import multipartkit/parser

const ct = "multipart/form-data; boundary=B"

fn one_part_body() -> BitArray {
  <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--B--\r\n":utf8,
  >>
}

pub fn body_too_large_test() {
  let body = one_part_body()
  let limits =
    Limits(
      max_body_bytes: 5,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  parser.parse_with_limits(body, ct, limits)
  |> should.equal(Error(BodyTooLarge(5)))
}

pub fn body_at_limit_succeeds_test() {
  let body = one_part_body()
  let exact = bit_array.byte_size(body)
  let limits =
    Limits(
      max_body_bytes: exact,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  case parser.parse_with_limits(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn part_too_large_test() {
  let body = one_part_body()
  let limits =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 4,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  // body "hello" is 5 bytes; limit 4 → exceeds.
  parser.parse_with_limits(body, ct, limits)
  |> should.equal(Error(PartTooLarge(4)))
}

pub fn part_at_limit_succeeds_test() {
  let body = one_part_body()
  let limits =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 5,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  case parser.parse_with_limits(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn too_many_parts_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--B--\r\n":utf8,
  >>
  let limits =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 1,
      max_header_bytes: 1000,
    )
  parser.parse_with_limits(body, ct, limits)
  |> should.equal(Error(TooManyParts(1)))
}

pub fn header_too_large_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Custom: very-long-header-value-here\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  let limits =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 10,
    )
  parser.parse_with_limits(body, ct, limits)
  |> should.equal(Error(HeaderTooLarge(10)))
}

pub fn limit_includes_blank_line_terminator_test() {
  // Header line "Content-Disposition: form-data; name=\"a\"\r\n" is 42 bytes;
  // blank-line terminator "\r\n" adds 2 bytes; so body_start - cursor = 44.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  let limits =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 44,
    )
  case parser.parse_with_limits(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
  let strict =
    Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 43,
    )
  parser.parse_with_limits(body, ct, strict)
  |> should.equal(Error(HeaderTooLarge(43)))
}
