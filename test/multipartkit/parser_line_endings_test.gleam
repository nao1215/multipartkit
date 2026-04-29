import gleam/option.{Some}
import gleeunit/should
import multipartkit/parser

const ct = "multipart/form-data; boundary=B"

pub fn parse_lf_only_line_endings_test() {
  let body = <<
    "--B\nContent-Disposition: form-data; name=\"a\"\n\nhello\n--B--\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.name |> should.equal(Some("a"))
  field_part.body |> should.equal(<<"hello":utf8>>)
}

pub fn parse_mixed_line_endings_test() {
  // CRLF for delimiter terminators; LF inside headers/body terminator.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\nContent-Type: text/plain\r\n\nhello\r\n--B--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.name |> should.equal(Some("a"))
  field_part.body |> should.equal(<<"hello":utf8>>)
}

pub fn parse_bare_cr_inside_body_is_preserved_test() {
  // A bare CR not followed by LF must remain in the body bytes.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x\"\r\nContent-Type: application/octet-stream\r\n\r\nfoo":utf8,
    13, "bar\r\n--B--\r\n":utf8,
  >>
  let assert Ok([file_part]) = parser.parse(body, ct)
  file_part.body |> should.equal(<<"foo":utf8, 13, "bar":utf8>>)
}

pub fn parse_lf_terminated_closing_test() {
  let body = <<
    "--B\nContent-Disposition: form-data; name=\"a\"\n\nx\n--B--\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<"x":utf8>>)
}
