import gleam/option.{Some}
import gleeunit
import gleeunit/should
import multipartkit
import multipartkit/form
import multipartkit/limit
import multipartkit/part
import multipartkit/query

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn facade_round_trip_test() {
  let form_value =
    form.new()
    |> form.add_field("title", "hello")
    |> form.add_file("avatar", "a.bin", "application/octet-stream", <<1, 2, 3>>)

  let #(content_type, body) = multipartkit.encode_form(form_value)
  let assert Ok(parts) = multipartkit.parse(body, content_type)

  parts
  |> query.required_field("title")
  |> should.equal(Ok("hello"))

  let assert Ok(file_part) = query.required_file(parts, "avatar")
  part.body(file_part)
  |> should.equal(<<1, 2, 3>>)
  part.filename(file_part)
  |> should.equal(Some("a.bin"))
}

pub fn default_limits_facade_test() {
  let limits = multipartkit.default_limits()
  limit.max_body_bytes(limits)
  |> should.equal(10_000_000)
  limit.max_part_bytes(limits)
  |> should.equal(5_000_000)
  limit.max_parts(limits)
  |> should.equal(100)
  limit.max_header_bytes(limits)
  |> should.equal(16_384)
}
