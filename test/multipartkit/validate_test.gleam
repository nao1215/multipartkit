import gleam/option.{type Option, None, Some}
import gleeunit/should
import multipartkit.{type Part, DisallowedContentType}

fn build_part(content_type: Option(String)) -> Part {
  let headers = case content_type {
    Some(value) -> [#("Content-Type", value)]
    None -> []
  }
  let assert Ok(p) = multipartkit.new_part(headers:, body: <<>>)
  p
}

pub fn allowed_content_types_match_test() {
  let p = build_part(Some("image/png"))
  let assert Ok(_) = multipartkit.allowed_content_types(p, ["image/png"])
}

pub fn allowed_content_types_match_case_insensitive_test() {
  let p = build_part(Some("Image/PNG"))
  let assert Ok(_) = multipartkit.allowed_content_types(p, ["image/png"])
}

pub fn allowed_content_types_strips_parameters_test() {
  let p = build_part(Some("text/plain; charset=utf-8"))
  let assert Ok(_) = multipartkit.allowed_content_types(p, ["text/plain"])
}

pub fn allowed_content_types_disallowed_test() {
  let p = build_part(Some("application/octet-stream"))
  multipartkit.allowed_content_types(p, ["image/png", "image/jpeg"])
  |> should.equal(Error(DisallowedContentType("application/octet-stream")))
}

pub fn allowed_content_types_with_no_content_type_test() {
  let p = build_part(None)
  multipartkit.allowed_content_types(p, ["image/png"])
  |> should.equal(Error(DisallowedContentType("")))
}
