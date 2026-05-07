import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/error.{InvalidUtf8Field, MissingField, MissingFile}
import multipartkit/part.{type Part}
import multipartkit/query

fn text_part(name: String, body: BitArray) -> Part {
  let assert Ok(p) =
    part.new(
      headers: [],
      name: Some(name),
      filename: None,
      content_type: None,
      body: body,
    )
  p
}

fn file_part(name: String, filename: String, body: BitArray) -> Part {
  let assert Ok(p) =
    part.new(
      headers: [],
      name: Some(name),
      filename: Some(filename),
      content_type: None,
      body: body,
    )
  p
}

fn anonymous_part(body: BitArray) -> Part {
  let assert Ok(p) =
    part.new(
      headers: [],
      name: None,
      filename: None,
      content_type: None,
      body: body,
    )
  p
}

pub fn field_returns_first_match_test() {
  let parts = [
    text_part("a", <<"first":utf8>>),
    text_part("a", <<"second":utf8>>),
  ]
  query.field(parts, "a") |> should.equal(Some("first"))
}

pub fn field_returns_none_when_missing_test() {
  query.field([text_part("b", <<"x":utf8>>)], "a")
  |> should.equal(None)
}

pub fn field_returns_none_for_invalid_utf8_test() {
  let parts = [text_part("a", <<0xFF, 0xFE>>)]
  query.field(parts, "a") |> should.equal(None)
}

pub fn required_field_present_test() {
  query.required_field([text_part("a", <<"v":utf8>>)], "a")
  |> should.equal(Ok("v"))
}

pub fn required_field_missing_test() {
  query.required_field([], "a")
  |> should.equal(Error(MissingField("a")))
}

pub fn required_field_invalid_utf8_test() {
  let parts = [text_part("a", <<0xFF>>)]
  query.required_field(parts, "a")
  |> should.equal(Error(InvalidUtf8Field("a")))
}

pub fn fields_returns_all_in_order_test() {
  let parts = [
    text_part("k", <<"1":utf8>>),
    text_part("other", <<"x":utf8>>),
    text_part("k", <<"2":utf8>>),
  ]
  query.fields(parts, "k") |> should.equal(["1", "2"])
}

pub fn fields_skips_invalid_utf8_silently_test() {
  let parts = [text_part("k", <<"a":utf8>>), text_part("k", <<0xFF>>)]
  query.fields(parts, "k") |> should.equal(["a"])
}

pub fn file_returns_first_match_test() {
  let parts = [
    text_part("k", <<"x":utf8>>),
    file_part("upload", "a.txt", <<"hi":utf8>>),
    file_part("upload", "b.txt", <<"bye":utf8>>),
  ]
  let assert Some(found) = query.file(parts, "upload")
  part.filename(found) |> should.equal(Some("a.txt"))
}

pub fn file_includes_empty_filename_test() {
  // Spec: filename = Some("") still counts as a file (unselected file input).
  let parts = [file_part("upload", "", <<>>)]
  let assert Some(found) = query.file(parts, "upload")
  part.filename(found) |> should.equal(Some(""))
}

pub fn required_file_missing_test() {
  query.required_file([], "x") |> should.equal(Error(MissingFile("x")))
}

pub fn files_returns_all_test() {
  let parts = [
    file_part("docs", "a", <<>>),
    file_part("other", "x", <<>>),
    file_part("docs", "b", <<>>),
  ]
  let result = query.files(parts, "docs")
  case result {
    [first, second] -> {
      part.filename(first) |> should.equal(Some("a"))
      part.filename(second) |> should.equal(Some("b"))
    }
    _ -> should.fail()
  }
}

pub fn names_distinct_first_appearance_order_test() {
  let parts = [
    text_part("a", <<>>),
    text_part("b", <<>>),
    text_part("a", <<>>),
    file_part("c", "x", <<>>),
  ]
  query.names(parts) |> should.equal(["a", "b", "c"])
}

pub fn anonymous_parts_are_skipped_test() {
  let parts = [anonymous_part(<<"hidden":utf8>>), text_part("a", <<"v":utf8>>)]
  query.field(parts, "a") |> should.equal(Some("v"))
  query.names(parts) |> should.equal(["a"])
}

pub fn name_match_is_case_sensitive_test() {
  // Per RFC 7578 the field name is case-sensitive.
  query.field([text_part("Name", <<"v":utf8>>)], "name")
  |> should.equal(None)
}

pub fn part_with_filename_is_not_a_text_field_test() {
  let parts = [file_part("name", "x", <<"file":utf8>>)]
  query.field(parts, "name") |> should.equal(None)
}
