import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import multipartkit.{InvalidHeaderValue}

fn round_trip(parts: List(multipartkit.Part)) -> List(multipartkit.Part) {
  let #(content_type, body) = multipartkit.encode_form(parts)
  let assert Ok(parsed) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  parsed
}

pub fn new_field_sets_name_and_body_test() {
  let assert Ok(part) = multipartkit.new_field(name: "a", value: "1")
  multipartkit.name(part) |> should.equal(Some("a"))
  multipartkit.filename(part) |> should.equal(None)
  multipartkit.content_type(part) |> should.equal(None)
  multipartkit.body(part) |> should.equal(<<"1":utf8>>)
  multipartkit.headers(part)
  |> should.equal([#("Content-Disposition", "form-data; name=\"a\"")])
}

pub fn new_file_sets_metadata_test() {
  let assert Ok(part) =
    multipartkit.new_file(
      name: "upload",
      filename: "doc.pdf",
      content_type: "application/pdf",
      body: <<"%PDF":utf8>>,
    )
  multipartkit.name(part) |> should.equal(Some("upload"))
  multipartkit.filename(part) |> should.equal(Some("doc.pdf"))
  multipartkit.content_type(part) |> should.equal(Some("application/pdf"))
  multipartkit.body(part) |> should.equal(<<"%PDF":utf8>>)
}

pub fn positional_arguments_test() {
  let assert Ok(field) = multipartkit.new_field("k", "v")
  let assert Ok(file) =
    multipartkit.new_file("u", "file.png", "image/png", <<137, 80, 78, 71>>)
  multipartkit.name(field) |> should.equal(Some("k"))
  multipartkit.filename(file) |> should.equal(Some("file.png"))
}

pub fn parts_round_trip_unchanged_test() {
  let assert Ok(name) = multipartkit.new_field(name: "name", value: "Alice")
  let assert Ok(notes) =
    multipartkit.new_field(name: "notes", value: "hello world")
  let assert Ok(avatar) =
    multipartkit.new_file(
      name: "avatar",
      filename: "a.png",
      content_type: "image/png",
      body: <<0x89, 0x50, 0x4E, 0x47>>,
    )
  let parts = [name, notes, avatar]
  round_trip(parts) |> should.equal(parts)
}

pub fn quotes_and_backslashes_round_trip_test() {
  let assert Ok(part) =
    multipartkit.new_file(
      name: "a\"b\\c",
      filename: "x \"y\".txt",
      content_type: "text/plain",
      body: <<"value with \" quote":utf8>>,
    )
  let assert [parsed] = round_trip([part])
  parsed |> should.equal(part)
  multipartkit.name(parsed) |> should.equal(Some("a\"b\\c"))
  multipartkit.filename(parsed) |> should.equal(Some("x \"y\".txt"))
}

pub fn value_may_contain_newlines_test() {
  // The value is the part body, not a header line.
  let assert Ok(part) =
    multipartkit.new_field(name: "ok", value: "value\nwith\r\nnewlines")
  multipartkit.body(part) |> should.equal(<<"value\nwith\r\nnewlines":utf8>>)
}

pub fn new_field_rejects_header_breaking_bytes_in_name_test() {
  list.each(["bad\nname", "bad\rname", "bad\r\nname", "bad\u{0}name"], fn(name) {
    multipartkit.new_field(name:, value: "value")
    |> should.equal(Error(InvalidHeaderValue("Content-Disposition", name)))
  })
}

pub fn new_file_rejects_header_breaking_bytes_test() {
  // #41: with the old lenient builder, `fi\nle.png` silently became
  // `file.png`.
  multipartkit.new_file("u", "fi\nle.png", "image/png", <<>>)
  |> should.equal(
    Error(InvalidHeaderValue("Content-Disposition", "fi\nle.png")),
  )
  multipartkit.new_file("u", "fi\r\nle.png", "image/png", <<>>)
  |> should.equal(
    Error(InvalidHeaderValue("Content-Disposition", "fi\r\nle.png")),
  )
  multipartkit.new_file("u\nname", "file.png", "image/png", <<>>)
  |> should.equal(Error(InvalidHeaderValue("Content-Disposition", "u\nname")))
  multipartkit.new_file("u", "file.png", "image/png\nX-Evil: 1", <<>>)
  |> should.equal(
    Error(InvalidHeaderValue("Content-Type", "image/png\nX-Evil: 1")),
  )
}

pub fn non_ascii_filename_with_newline_is_rejected_test() {
  // A non-ASCII filename goes out percent-encoded in `filename*`, so the
  // newline has to be caught before encoding.
  multipartkit.new_file("u", "ü\n.txt", "text/plain", <<>>)
  |> should.equal(Error(InvalidHeaderValue("Content-Disposition", "ü\n.txt")))
}

pub fn name_is_checked_before_filename_and_content_type_test() {
  multipartkit.new_file("u\n", "f\n", "t\n", <<>>)
  |> should.equal(Error(InvalidHeaderValue("Content-Disposition", "u\n")))
}
