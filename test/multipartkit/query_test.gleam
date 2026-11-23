import gleam/option.{Some}
import gleeunit/should
import multipartkit.{type Part, InvalidUtf8Field, MissingField, MissingFile}

fn text_part(name: String, body: BitArray) -> Part {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"" <> name <> "\"")],
      body:,
    )
  p
}

fn file_part(name: String, filename: String, body: BitArray) -> Part {
  let assert Ok(p) =
    multipartkit.new_file(name:, filename:, content_type: "text/plain", body:)
  p
}

fn anonymous_part(body: BitArray) -> Part {
  let assert Ok(p) = multipartkit.new_part(headers: [], body: body)
  p
}

pub fn field_returns_first_match_test() {
  let parts = [
    text_part("a", <<"first":utf8>>),
    text_part("a", <<"second":utf8>>),
  ]
  multipartkit.field(parts, "a") |> should.equal(Ok("first"))
}

pub fn field_present_test() {
  multipartkit.field([text_part("a", <<"v":utf8>>)], "a")
  |> should.equal(Ok("v"))
}

pub fn field_missing_test() {
  multipartkit.field([text_part("b", <<"x":utf8>>)], "a")
  |> should.equal(Error(MissingField("a")))
}

pub fn field_invalid_utf8_test() {
  let parts = [text_part("a", <<0xFF>>)]
  multipartkit.field(parts, "a")
  |> should.equal(Error(InvalidUtf8Field("a")))
}

pub fn fields_returns_all_in_order_test() {
  let parts = [
    text_part("k", <<"1":utf8>>),
    text_part("other", <<"x":utf8>>),
    text_part("k", <<"2":utf8>>),
  ]
  multipartkit.fields(parts, "k") |> should.equal(["1", "2"])
}

pub fn fields_skips_invalid_utf8_silently_test() {
  let parts = [text_part("k", <<"a":utf8>>), text_part("k", <<0xFF>>)]
  multipartkit.fields(parts, "k") |> should.equal(["a"])
}

pub fn file_returns_first_match_test() {
  let parts = [
    text_part("k", <<"x":utf8>>),
    file_part("upload", "a.txt", <<"hi":utf8>>),
    file_part("upload", "b.txt", <<"bye":utf8>>),
  ]
  let assert Ok(found) = multipartkit.file(parts, "upload")
  multipartkit.filename(found) |> should.equal(Some("a.txt"))
}

pub fn file_includes_empty_filename_test() {
  // Spec: filename = Some("") still counts as a file (unselected file input).
  let parts = [file_part("upload", "", <<>>)]
  let assert Ok(found) = multipartkit.file(parts, "upload")
  multipartkit.filename(found) |> should.equal(Some(""))
}

pub fn file_missing_test() {
  multipartkit.file([], "x") |> should.equal(Error(MissingFile("x")))
}

pub fn files_returns_all_test() {
  let parts = [
    file_part("docs", "a", <<>>),
    file_part("other", "x", <<>>),
    file_part("docs", "b", <<>>),
  ]
  let result = multipartkit.files(parts, "docs")
  case result {
    [first, second] -> {
      multipartkit.filename(first) |> should.equal(Some("a"))
      multipartkit.filename(second) |> should.equal(Some("b"))
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
  multipartkit.names(parts) |> should.equal(["a", "b", "c"])
}

pub fn anonymous_parts_are_skipped_test() {
  let parts = [anonymous_part(<<"hidden":utf8>>), text_part("a", <<"v":utf8>>)]
  multipartkit.field(parts, "a") |> should.equal(Ok("v"))
  multipartkit.names(parts) |> should.equal(["a"])
}

pub fn name_match_is_case_sensitive_test() {
  // Per RFC 7578 the field name is case-sensitive.
  multipartkit.field([text_part("Name", <<"v":utf8>>)], "name")
  |> should.equal(Error(MissingField("name")))
}

pub fn part_with_filename_is_not_a_text_field_test() {
  let parts = [file_part("name", "x", <<"file":utf8>>)]
  multipartkit.field(parts, "name") |> should.equal(Error(MissingField("name")))
}
