//// Regression tests for problems found in review of the API rework.

import gleam/option.{None, Some}
import gleam/yielder
import gleeunit/should
import multipartkit.{
  BodyTooLarge, HeaderTooLarge, InvalidHeaderName, InvalidHeaderValue,
  InvalidQuotedPair,
}
import multipartkit/stream

fn limits(max_body_bytes: Int, max_header_bytes: Int) -> multipartkit.Limits {
  multipartkit.Limits(
    ..multipartkit.default_limits,
    max_body_bytes:,
    max_header_bytes:,
  )
}

pub fn parse_reports_invalid_quoted_pair_test() {
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"\\\u{0001}x\"\r\n\r\nv\r\n--b--\r\n":utf8,
  >>
  multipartkit.parse(
    body,
    "multipart/form-data; boundary=b",
    multipartkit.default_limits,
  )
  |> should.equal(Error(InvalidQuotedPair("form-data; name=\"\\\u{0001}x\"")))
}

pub fn new_part_rejects_leading_whitespace_in_header_name_test() {
  // The parser reads such a line as a folded header.
  multipartkit.new_part(headers: [#(" X", "v")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName(" X")))
  multipartkit.new_part(headers: [#("\tX", "v")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName("\tX")))
}

pub fn quote_followed_by_combining_mark_is_escaped_test() {
  let name = "a\"\u{0301}; filename=\"x"
  let assert Ok(part) = multipartkit.new_field(name:, value: "v")
  multipartkit.header(part, "content-disposition")
  |> should.equal(Ok("form-data; name=\"a\\\"\u{0301}; filename=\\\"x\""))
  let #(content_type, body) = multipartkit.encode_form([part])
  let assert Ok([parsed]) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  multipartkit.name(parsed) |> should.equal(multipartkit.name(part))
  multipartkit.filename(parsed) |> should.equal(None)
}

pub fn empty_body_epilogue_counts_in_stream_test() {
  let content_type = "multipart/mixed; boundary=b"
  let input = <<"--b--\r\n0123456789abc":utf8>>
  multipartkit.parse(input, content_type, limits(10, 100))
  |> should.equal(Error(BodyTooLarge(10)))
  let assert Ok(parts) =
    stream.parse(
      yielder.from_list([<<"--b--\r\n":utf8>>, <<"0123456789abc":utf8>>]),
      content_type,
      limits(10, 100),
    )
  yielder.to_list(parts) |> should.equal([Error(BodyTooLarge(10))])
}

pub fn unterminated_headers_hit_the_header_limit_test() {
  let content_type = "multipart/mixed; boundary=b"
  let header = <<"X: aaaaaaaaaaaaaaaaaaaaaaaaa":utf8>>
  let input = <<"--b\r\n":utf8, header:bits>>
  multipartkit.parse(input, content_type, limits(1000, 5))
  |> should.equal(Error(HeaderTooLarge(5)))
  let assert Ok(parts) =
    stream.parse(
      yielder.from_list([<<"--b\r\n":utf8>>, header, header, header]),
      content_type,
      limits(1000, 5),
    )
  yielder.to_list(parts) |> should.equal([Error(HeaderTooLarge(5))])
}

pub fn extended_filename_with_control_bytes_is_not_used_test() {
  // A `filename*` that decodes to CR, LF or NUL is ignored, so the part
  // falls back to the plain `filename` and never holds those bytes.
  let value =
    "form-data; name=\"f\"; filename=\"ab\"; filename*=UTF-8''a%0D%0Ab%00"
  let assert Ok(parsed) = multipartkit.parse_content_disposition(value)
  parsed.filename |> should.equal(Some("ab"))
}

pub fn control_only_name_is_reported_as_header_breaking_test() {
  multipartkit.new_field(name: "\r\n", value: "v")
  |> should.equal(Error(InvalidHeaderValue("Content-Disposition", "\r\n")))
}
