import gleam/option.{type Option, None, Some}
import gleeunit/should
import multipartkit/error.{DisallowedContentType, PartTooLarge}
import multipartkit/part.{type Part}
import multipartkit/validate

fn build_part(name: String, ct: Option(String), body: BitArray) -> Part {
  let assert Ok(p) =
    part.new(
      headers: [],
      name: Some(name),
      filename: None,
      content_type: ct,
      body: body,
    )
  p
}

pub fn has_field_true_test() {
  let parts = [build_part("a", None, <<>>)]
  validate.has_field(parts, "a") |> should.equal(True)
}

pub fn has_field_false_test() {
  validate.has_field([], "a") |> should.equal(False)
}

pub fn max_file_size_within_limit_test() {
  let p = build_part("f", Some("image/png"), <<1, 2>>)
  let assert Ok(_) = validate.max_file_size(p, 5)
}

pub fn max_file_size_at_limit_test() {
  let p = build_part("f", Some("image/png"), <<1, 2, 3>>)
  let assert Ok(_) = validate.max_file_size(p, 3)
}

pub fn max_file_size_exceeds_test() {
  let p = build_part("f", None, <<1, 2, 3, 4>>)
  validate.max_file_size(p, 3)
  |> should.equal(Error(PartTooLarge(3)))
}

pub fn allowed_content_types_match_test() {
  let p = build_part("f", Some("image/png"), <<>>)
  let assert Ok(_) = validate.allowed_content_types(p, ["image/png"])
}

pub fn allowed_content_types_match_case_insensitive_test() {
  let p = build_part("f", Some("Image/PNG"), <<>>)
  let assert Ok(_) = validate.allowed_content_types(p, ["image/png"])
}

pub fn allowed_content_types_strips_parameters_test() {
  let p = build_part("f", Some("text/plain; charset=utf-8"), <<>>)
  let assert Ok(_) = validate.allowed_content_types(p, ["text/plain"])
}

pub fn allowed_content_types_disallowed_test() {
  let p = build_part("f", Some("application/octet-stream"), <<>>)
  validate.allowed_content_types(p, ["image/png", "image/jpeg"])
  |> should.equal(Error(DisallowedContentType("application/octet-stream")))
}

pub fn allowed_content_types_with_no_content_type_test() {
  let p = build_part("f", None, <<>>)
  validate.allowed_content_types(p, ["image/png"])
  |> should.equal(Error(DisallowedContentType("")))
}
