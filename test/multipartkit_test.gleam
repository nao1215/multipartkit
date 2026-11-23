import gleam/option.{Some}
import gleeunit
import gleeunit/should
import multipartkit
import support

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn facade_round_trip_test() {
  let form_value =
    []
    |> support.add_field("title", "hello")
    |> support.add_file("avatar", "a.bin", "application/octet-stream", <<
      1,
      2,
      3,
    >>)

  let #(content_type, body) = multipartkit.encode_form(form_value)
  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)

  parts
  |> multipartkit.field("title")
  |> should.equal(Ok("hello"))

  let assert Ok(file_part) = multipartkit.file(parts, "avatar")
  multipartkit.body(file_part)
  |> should.equal(<<1, 2, 3>>)
  multipartkit.filename(file_part)
  |> should.equal(Some("a.bin"))
}

pub fn default_limits_facade_test() {
  let limits = multipartkit.default_limits
  limits.max_body_bytes
  |> should.equal(10_000_000)
  limits.max_part_bytes
  |> should.equal(5_000_000)
  limits.max_parts
  |> should.equal(100)
  limits.max_header_bytes
  |> should.equal(16_384)
}
