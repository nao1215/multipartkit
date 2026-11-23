import gleeunit/should
import multipartkit.{
  InvalidBoundary, InvalidContentType, MissingBoundary, UnsupportedMediaType,
}

pub fn boundary_simple_test() {
  multipartkit.boundary("multipart/form-data; boundary=abc")
  |> should.equal(Ok("abc"))
}

pub fn boundary_with_quotes_test() {
  multipartkit.boundary("multipart/form-data; boundary=\"abc 123\"")
  |> should.equal(Ok("abc 123"))
}

pub fn boundary_case_insensitive_param_name_test() {
  multipartkit.boundary("multipart/form-data; BOUNDARY=xyz")
  |> should.equal(Ok("xyz"))
}

pub fn boundary_after_other_params_test() {
  multipartkit.boundary("multipart/form-data; charset=utf-8; boundary=----foo")
  |> should.equal(Ok("----foo"))
}

pub fn boundary_first_match_wins_on_duplicates_test() {
  multipartkit.boundary("multipart/form-data; boundary=first; boundary=second")
  |> should.equal(Ok("first"))
}

pub fn boundary_priority_invalid_content_type_test() {
  multipartkit.boundary("not a media type")
  |> should.equal(Error(InvalidContentType("not a media type")))
}

pub fn boundary_priority_unsupported_media_type_test() {
  multipartkit.boundary("text/plain; boundary=abc")
  |> should.equal(Error(UnsupportedMediaType("text/plain")))
}

pub fn boundary_priority_missing_boundary_test() {
  multipartkit.boundary("multipart/form-data")
  |> should.equal(Error(MissingBoundary))
}

pub fn boundary_priority_empty_param_value_treated_as_invalid_test() {
  let assert Error(InvalidContentType(_)) =
    multipartkit.boundary("multipart/form-data; boundary=")
}

pub fn boundary_invalid_with_disallowed_char_test() {
  let assert Error(InvalidBoundary(value)) =
    multipartkit.boundary("multipart/form-data; boundary=\"abc<>\"")
  value
  |> should.equal("abc<>")
}

pub fn boundary_invalid_too_long_test() {
  let long_boundary =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let assert Error(InvalidBoundary(value)) =
    multipartkit.boundary("multipart/form-data; boundary=" <> long_boundary)
  value
  |> should.equal(long_boundary)
}

pub fn boundary_accepts_multipart_mixed_test() {
  multipartkit.boundary("multipart/mixed; boundary=Q")
  |> should.equal(Ok("Q"))
}

pub fn boundary_rejects_bare_multipart_test() {
  multipartkit.boundary("multipart/")
  |> should.equal(Error(InvalidContentType("multipart/")))
}

pub fn boundary_unsupported_with_uppercase_test() {
  multipartkit.boundary("Application/Json; boundary=abc")
  |> should.equal(Error(UnsupportedMediaType("Application/Json")))
}

pub fn boundary_with_leading_ows_test() {
  multipartkit.boundary("   multipart/form-data; boundary=abc")
  |> should.equal(Ok("abc"))
}
