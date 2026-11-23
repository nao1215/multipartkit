//// The Content-Type checks of `parse`: which boundary it reads, and which
//// error a bad Content-Type gives.

import multipartkit.{
  InvalidBoundary, InvalidContentType, MissingBoundary, UnsupportedMediaType,
}

/// Parses a body with no parts, which succeeds only when `content_type`
/// names `boundary`.
fn reads_boundary(content_type: String, boundary: String) -> Bool {
  multipartkit.parse(
    <<"--":utf8, boundary:utf8, "--":utf8>>,
    content_type,
    multipartkit.default_limits,
  )
  == Ok([])
}

fn content_type_error(content_type: String) {
  multipartkit.parse(<<>>, content_type, multipartkit.default_limits)
}

pub fn boundary_simple_test() {
  assert reads_boundary("multipart/form-data; boundary=abc", "abc")
}

pub fn boundary_with_quotes_test() {
  assert reads_boundary("multipart/form-data; boundary=\"abc 123\"", "abc 123")
}

pub fn boundary_case_insensitive_param_name_test() {
  assert reads_boundary("multipart/form-data; BOUNDARY=xyz", "xyz")
}

pub fn boundary_after_other_params_test() {
  assert reads_boundary(
    "multipart/form-data; charset=utf-8; boundary=----foo",
    "----foo",
  )
}

pub fn boundary_duplicates_are_rejected_test() {
  let content_type = "multipart/form-data; boundary=first; boundary=second"
  assert content_type_error(content_type)
    == Error(InvalidContentType(content_type))
}

pub fn boundary_priority_invalid_content_type_test() {
  assert content_type_error("not a media type")
    == Error(InvalidContentType("not a media type"))
}

pub fn boundary_priority_unsupported_media_type_test() {
  assert content_type_error("text/plain; boundary=abc")
    == Error(UnsupportedMediaType("text/plain"))
}

pub fn boundary_priority_missing_boundary_test() {
  assert content_type_error("multipart/form-data") == Error(MissingBoundary)
}

pub fn boundary_priority_empty_param_value_treated_as_invalid_test() {
  let assert Error(InvalidContentType(_)) =
    content_type_error("multipart/form-data; boundary=")
}

pub fn boundary_invalid_with_disallowed_char_test() {
  assert content_type_error("multipart/form-data; boundary=\"abc<>\"")
    == Error(InvalidBoundary("abc<>"))
}

pub fn boundary_invalid_too_long_test() {
  let long_boundary =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  assert content_type_error("multipart/form-data; boundary=" <> long_boundary)
    == Error(InvalidBoundary(long_boundary))
}

pub fn boundary_accepts_multipart_mixed_test() {
  assert reads_boundary("multipart/mixed; boundary=Q", "Q")
}

pub fn boundary_rejects_bare_multipart_test() {
  assert content_type_error("multipart/")
    == Error(InvalidContentType("multipart/"))
}

pub fn boundary_unsupported_with_uppercase_test() {
  assert content_type_error("Application/Json; boundary=abc")
    == Error(UnsupportedMediaType("Application/Json"))
}

pub fn boundary_with_leading_ows_test() {
  assert reads_boundary("   multipart/form-data; boundary=abc", "abc")
}

pub fn quoted_boundary_with_a_control_escape_is_invalid_test() {
  // RFC 9110 §5.6.4: a quoted-pair cannot escape a control character.
  let content_type = "multipart/form-data; boundary=\"a\\\u{0001}\""
  assert content_type_error(content_type)
    == Error(InvalidContentType(content_type))
}
