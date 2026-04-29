import gleeunit/should
import multipartkit/error.{
  InvalidBoundary, InvalidContentDisposition, InvalidContentType, InvalidHeader,
  MissingBoundary, UnexpectedEndOfInput, UnsupportedMediaType,
}
import multipartkit/parser

pub fn invalid_content_type_test() {
  parser.parse(<<>>, "garbage")
  |> should.equal(Error(InvalidContentType("garbage")))
}

pub fn unsupported_media_type_test() {
  parser.parse(<<>>, "text/plain; boundary=x")
  |> should.equal(Error(UnsupportedMediaType("text/plain")))
}

pub fn missing_boundary_test() {
  parser.parse(<<>>, "multipart/form-data")
  |> should.equal(Error(MissingBoundary))
}

pub fn invalid_boundary_test() {
  parser.parse(<<>>, "multipart/form-data; boundary=\"<bad>\"")
  |> should.equal(Error(InvalidBoundary("<bad>")))
}

pub fn unexpected_eof_no_delimiter_test() {
  parser.parse(<<"random body":utf8>>, "multipart/form-data; boundary=ABC")
  |> should.equal(Error(UnexpectedEndOfInput))
}

pub fn unexpected_eof_truncated_close_test() {
  let body = <<
    "--ABC\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nfoo\r\n":utf8,
  >>
  parser.parse(body, "multipart/form-data; boundary=ABC")
  |> should.equal(Error(UnexpectedEndOfInput))
}

pub fn invalid_header_no_colon_test() {
  let body = <<
    "--B\r\nNoColonHere\r\n\r\nfoo\r\n--B--\r\n":utf8,
  >>
  let assert Error(InvalidHeader(_)) =
    parser.parse(body, "multipart/form-data; boundary=B")
}

pub fn invalid_header_obs_fold_rejected_test() {
  // RFC 7230 §3.2.4 forbids line-folding (continuation lines starting with
  // SP/HT). We reject it as InvalidHeader.
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n folded\r\n\r\nx\r\n--B--\r\n":utf8,
  >>
  let assert Error(InvalidHeader(_)) =
    parser.parse(body, "multipart/form-data; boundary=B")
}

pub fn invalid_content_disposition_test() {
  let body = <<
    "--B\r\nContent-Disposition: garbage??\r\n\r\nfoo\r\n--B--\r\n":utf8,
  >>
  let assert Error(InvalidContentDisposition(_)) =
    parser.parse(body, "multipart/form-data; boundary=B")
}
