import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/parser

const ct = "multipart/form-data; boundary=BOUNDARY"

const dash = "--BOUNDARY\r\n"

const close = "--BOUNDARY--\r\n"

pub fn parse_single_text_field_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.name |> should.equal(Some("a"))
  field_part.filename |> should.equal(None)
  field_part.content_type |> should.equal(None)
  field_part.body |> should.equal(<<"hello":utf8>>)
}

pub fn parse_two_fields_preserves_order_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n22\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([first, second]) = parser.parse(body, ct)
  first.name |> should.equal(Some("a"))
  first.body |> should.equal(<<"1":utf8>>)
  second.name |> should.equal(Some("b"))
  second.body |> should.equal(<<"22":utf8>>)
}

pub fn parse_file_part_with_content_type_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n":utf8,
    1, 2, 3, "\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([file_part]) = parser.parse(body, ct)
  file_part.name |> should.equal(Some("upload"))
  file_part.filename |> should.equal(Some("a.bin"))
  file_part.content_type |> should.equal(Some("application/octet-stream"))
  file_part.body |> should.equal(<<1, 2, 3>>)
}

pub fn parse_with_preamble_test() {
  let body = <<
    "ignored preamble\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<"x":utf8>>)
}

pub fn parse_with_epilogue_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--BOUNDARY--\r\nepilogue text":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<"x":utf8>>)
}

pub fn parse_empty_body_part_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"empty\"\r\n\r\n\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<>>)
  field_part.name |> should.equal(Some("empty"))
}

pub fn parse_empty_filename_is_a_file_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"\"\r\n\r\n\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([file_part]) = parser.parse(body, ct)
  file_part.name |> should.equal(Some("upload"))
  file_part.filename |> should.equal(Some(""))
  file_part.body |> should.equal(<<>>)
}

pub fn parse_immediate_close_returns_empty_test() {
  let body = <<close:utf8>>
  parser.parse(body, ct)
  |> should.equal(Ok([]))
}

pub fn parse_empty_header_block_with_blank_line_test() {
  // Empty header block, valid because the blank line directly follows the
  // first delimiter terminator.
  let body = <<dash:utf8, "\r\nbody\r\n":utf8, close:utf8>>
  let assert Ok([the_part]) = parser.parse(body, ct)
  the_part.headers |> should.equal([])
  the_part.body |> should.equal(<<"body":utf8>>)
}

pub fn parse_preserves_header_order_and_casing_test() {
  let body = <<
    "--BOUNDARY\r\nX-Custom: 1\r\nContent-Disposition: form-data; name=\"a\"\r\nx-custom: 2\r\n\r\nbody\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.headers
  |> should.equal([
    #("X-Custom", "1"),
    #("Content-Disposition", "form-data; name=\"a\""),
    #("x-custom", "2"),
  ])
}

pub fn parse_binary_body_is_byte_safe_test() {
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x\"\r\nContent-Type: application/octet-stream\r\n\r\n":utf8,
    0, 0xFF, 0xFE, 0x80, 0x00, 0x0A, "\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([file_part]) = parser.parse(body, ct)
  file_part.body |> should.equal(<<0, 0xFF, 0xFE, 0x80, 0x00, 0x0A>>)
}

pub fn parse_part_without_content_disposition_test() {
  // Per spec: parts without Content-Disposition are still surfaced but
  // queries skip them. derive_meta should produce all-None metadata.
  let body = <<
    "--BOUNDARY\r\nX-Custom: 1\r\n\r\npayload\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([the_part]) = parser.parse(body, ct)
  the_part.name |> should.equal(None)
  the_part.filename |> should.equal(None)
  the_part.body |> should.equal(<<"payload":utf8>>)
}

pub fn parse_browser_style_payload_test() {
  // Representative Chrome/Firefox style: multiple fields, file with content-type.
  let ct_value =
    "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"
  let body = <<
    "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n":utf8,
    "Content-Disposition: form-data; name=\"username\"\r\n\r\n":utf8,
    "alice\r\n":utf8, "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n":utf8,
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"face.png\"\r\n":utf8,
    "Content-Type: image/png\r\n\r\n":utf8, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A,
    0x1A, 0x0A, "\r\n":utf8,
    "------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n":utf8,
  >>
  let assert Ok([username_part, avatar_part]) = parser.parse(body, ct_value)
  username_part.name |> should.equal(Some("username"))
  username_part.body |> should.equal(<<"alice":utf8>>)
  avatar_part.name |> should.equal(Some("avatar"))
  avatar_part.filename |> should.equal(Some("face.png"))
  avatar_part.content_type |> should.equal(Some("image/png"))
  avatar_part.body
  |> should.equal(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)
}

pub fn parse_boundary_like_text_inside_body_test() {
  // A part body contains a string that LOOKS like a boundary but is missing
  // the line-start anchor.
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nfoo --BOUNDARY in body\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<"foo --BOUNDARY in body":utf8>>)
}

pub fn parse_no_preceding_crlf_for_first_delimiter_test() {
  // Spec: "boundary delimiter line is matched independently of the preceding
  // line ending: the parser accepts CRLF or LF immediately before the leading
  // `--`."  Here the very first delimiter appears at byte 0.
  let body = <<
    "--BOUNDARY\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--BOUNDARY--\r\n":utf8,
  >>
  let assert Ok([field_part]) = parser.parse(body, ct)
  field_part.body |> should.equal(<<"x":utf8>>)
}
