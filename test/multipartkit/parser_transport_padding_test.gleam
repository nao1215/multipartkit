import gleam/list
import gleam/option.{Some}
import gleeunit/should
import multipartkit

const ct = "multipart/form-data; boundary=BND"

pub fn parse_opening_delimiter_with_space_padding_test() {
  let body = <<
    "--BND  \r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--BND--\r\n":utf8,
  >>
  let assert Ok(parts) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  list.length(parts) |> should.equal(1)
  let assert [single] = parts
  multipartkit.name(single) |> should.equal(Some("a"))
  multipartkit.body(single) |> should.equal(<<"hello":utf8>>)
}

pub fn parse_inter_part_delimiter_with_tab_padding_test() {
  let body = <<
    "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--BND\t\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nworld\r\n--BND--\r\n":utf8,
  >>
  let assert Ok(parts) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  list.length(parts) |> should.equal(2)
  let assert [first, second] = parts
  multipartkit.name(first) |> should.equal(Some("a"))
  multipartkit.name(second) |> should.equal(Some("b"))
}

pub fn parse_closing_delimiter_with_padding_test() {
  let body = <<
    "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--BND--  \r\n":utf8,
  >>
  let assert Ok([field_part]) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  multipartkit.body(field_part) |> should.equal(<<"hello":utf8>>)
}

pub fn parse_lf_terminated_with_padding_test() {
  let body = <<
    "--BND \nContent-Disposition: form-data; name=\"a\"\n\nhi\n--BND--\n":utf8,
  >>
  let assert Ok([field_part]) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  multipartkit.body(field_part) |> should.equal(<<"hi":utf8>>)
}

pub fn parse_mixed_space_and_tab_padding_test() {
  // Multiple LWSP-chars (space, tab, space) in one delimiter.
  let body = <<
    "--BND \t \r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nv\r\n--BND--\r\n":utf8,
  >>
  let assert Ok([field_part]) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  multipartkit.name(field_part) |> should.equal(Some("a"))
  multipartkit.body(field_part) |> should.equal(<<"v":utf8>>)
}

pub fn parse_zero_padding_still_works_test() {
  // Sanity: previously-correct, padding-free bodies must still parse.
  let body = <<
    "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--BND--\r\n":utf8,
  >>
  let assert Ok([field_part]) =
    multipartkit.parse(body, ct, multipartkit.default_limits)
  multipartkit.body(field_part) |> should.equal(<<"hello":utf8>>)
}
