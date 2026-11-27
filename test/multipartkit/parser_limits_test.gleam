import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/yielder
import gleeunit/should
import multipartkit.{BodyTooLarge, HeaderTooLarge, PartTooLarge, TooManyParts}
import multipartkit/stream

const ct = "multipart/form-data; boundary=B"

fn one_part_body() -> BitArray {
  <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--B--\r\n":utf8,
  >>
}

pub fn body_too_large_test() {
  let body = one_part_body()
  let limits =
    multipartkit.Limits(
      max_body_bytes: 5,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  multipartkit.parse(body, ct, limits)
  |> should.equal(Error(BodyTooLarge(5)))
}

pub fn body_at_limit_succeeds_test() {
  let body = one_part_body()
  let exact = bit_array.byte_size(body)
  let limits =
    multipartkit.Limits(
      max_body_bytes: exact,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  case multipartkit.parse(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn part_too_large_test() {
  let body = one_part_body()
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 4,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  // body "hello" is 5 bytes; limit 4 → exceeds.
  multipartkit.parse(body, ct, limits)
  |> should.equal(Error(PartTooLarge(4)))
}

pub fn part_at_limit_succeeds_test() {
  let body = one_part_body()
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 5,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  case multipartkit.parse(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn too_many_parts_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--B--\r\n":utf8,
  >>
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 1,
      max_header_bytes: 1000,
    )
  multipartkit.parse(body, ct, limits)
  |> should.equal(Error(TooManyParts(1)))
}

pub fn header_too_large_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Custom: very-long-header-value-here\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 10,
    )
  multipartkit.parse(body, ct, limits)
  |> should.equal(Error(HeaderTooLarge(10)))
}

pub fn limit_includes_blank_line_terminator_test() {
  // Header line "Content-Disposition: form-data; name=\"a\"\r\n" is 42 bytes;
  // blank-line terminator "\r\n" adds 2 bytes; so body_start - cursor = 44.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 44,
    )
  case multipartkit.parse(body, ct, limits) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
  let strict =
    multipartkit.Limits(
      max_body_bytes: 1000,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 43,
    )
  multipartkit.parse(body, ct, strict)
  |> should.equal(Error(HeaderTooLarge(43)))
  // stream.parse draws the same line.
  assert stream_names(body, limits) == [Ok(Some("a"))]
  assert stream_names(body, strict) == [Error(HeaderTooLarge(43))]
}

fn stream_names(body: BitArray, limits: multipartkit.Limits) {
  let assert Ok(parts) = stream.parse(yielder.single(body), ct, limits)
  parts
  |> yielder.to_list
  |> list.map(result.map(_, stream.name))
}

pub fn zero_limit_rejects_any_part_test() {
  // Limits are plain numbers, so 0 is allowed and means "none".
  let assert Ok(field) = multipartkit.new_field(name: "a", value: "1")
  let #(content_type, body) = multipartkit.encode_form([field])
  let limits = multipartkit.Limits(..multipartkit.default_limits, max_parts: 0)
  multipartkit.parse(body, content_type, limits)
  |> should.equal(Error(multipartkit.TooManyParts(0)))
}
