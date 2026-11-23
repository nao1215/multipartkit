import gleeunit/should
import multipartkit.{
  InvalidBoundary, InvalidContentDisposition, InvalidContentType, InvalidHeader,
  MissingBoundary, UnexpectedEndOfInput, UnsupportedMediaType,
}

pub fn invalid_content_type_test() {
  multipartkit.parse(<<>>, "garbage", multipartkit.default_limits)
  |> should.equal(Error(InvalidContentType("garbage")))
}

pub fn unsupported_media_type_test() {
  multipartkit.parse(
    <<>>,
    "text/plain; boundary=x",
    multipartkit.default_limits,
  )
  |> should.equal(Error(UnsupportedMediaType("text/plain")))
}

pub fn missing_boundary_test() {
  multipartkit.parse(<<>>, "multipart/form-data", multipartkit.default_limits)
  |> should.equal(Error(MissingBoundary))
}

pub fn invalid_boundary_test() {
  multipartkit.parse(
    <<>>,
    "multipart/form-data; boundary=\"<bad>\"",
    multipartkit.default_limits,
  )
  |> should.equal(Error(InvalidBoundary("<bad>")))
}

pub fn unexpected_eof_no_delimiter_test() {
  multipartkit.parse(
    <<"random body":utf8>>,
    "multipart/form-data; boundary=ABC",
    multipartkit.default_limits,
  )
  |> should.equal(Error(UnexpectedEndOfInput))
}

pub fn unexpected_eof_truncated_close_test() {
  let body = <<
    "--ABC\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nfoo\r\n":utf8,
  >>
  multipartkit.parse(
    body,
    "multipart/form-data; boundary=ABC",
    multipartkit.default_limits,
  )
  |> should.equal(Error(UnexpectedEndOfInput))
}

pub fn invalid_header_no_colon_test() {
  let body = <<
    "--B\r\nNoColonHere\r\n\r\nfoo\r\n--B--\r\n":utf8,
  >>
  let assert Error(InvalidHeader(_)) =
    multipartkit.parse(
      body,
      "multipart/form-data; boundary=B",
      multipartkit.default_limits,
    )
}

pub fn folded_header_is_joined_to_the_line_before_test() {
  // RFC 5322 §2.2.3: a continuation line is unfolded, so this becomes
  // `form-data; name="a" folded`, which is not a valid Content-Disposition.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n folded\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  multipartkit.parse(
    body,
    "multipart/form-data; boundary=B",
    multipartkit.default_limits,
  )
  |> should.equal(
    Error(InvalidContentDisposition("form-data; name=\"a\" folded")),
  )
}

pub fn invalid_content_disposition_test() {
  let body = <<
    "--B\r\nContent-Disposition: garbage??\r\n\r\nfoo\r\n--B--\r\n":utf8,
  >>
  let assert Error(InvalidContentDisposition(_)) =
    multipartkit.parse(
      body,
      "multipart/form-data; boundary=B",
      multipartkit.default_limits,
    )
}
