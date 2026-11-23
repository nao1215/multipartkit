//// The README example and the doc comment examples, run on both targets.

import gleam/bit_array
import gleam/option.{None, Some}
import gleam/result
import gleam/yielder
import gleeunit/should
import multipartkit.{
  ContentDisposition, EmptyFieldName, InvalidBoundary, InvalidContentDisposition,
  InvalidHeaderValue, MissingField, UnsupportedMediaType,
}
import multipartkit/stream

// The request handler from the README.
fn read_upload(body: BitArray, content_type: String) {
  let limits = multipartkit.Limits(..multipartkit.default_limits, max_parts: 10)
  use parts <- result.try(multipartkit.parse(body, content_type, limits))
  use title <- result.try(multipartkit.field(parts, "title"))
  use avatar <- result.try(multipartkit.file(parts, "avatar"))
  use avatar <- result.try(
    multipartkit.allowed_content_types(avatar, ["image/png", "image/jpeg"]),
  )
  Ok(#(title, avatar))
}

pub fn readme_read_upload_test() {
  let assert Ok(title) = multipartkit.new_field(name: "title", value: "hello")
  let assert Ok(avatar) =
    multipartkit.new_file(
      name: "avatar",
      filename: "cat.png",
      content_type: "image/png",
      body: <<137, 80, 78, 71>>,
    )
  let #(content_type, body) = multipartkit.encode_form([title, avatar])
  read_upload(body, content_type) |> should.equal(Ok(#("hello", avatar)))

  let #(content_type, body) = multipartkit.encode_form([avatar])
  read_upload(body, content_type)
  |> should.equal(Error(MissingField("title")))
}

pub fn new_field_doc_test() {
  let assert Ok(title) = multipartkit.new_field(name: "title", value: "hello")
  multipartkit.name(title) |> should.equal(Some("title"))
  multipartkit.new_field(name: "", value: "hello")
  |> should.equal(Error(EmptyFieldName("")))
}

pub fn new_part_doc_test() {
  let assert Ok(part) =
    multipartkit.new_part(headers: [#("Content-Type", "text/plain")], body: <<
      "hi",
    >>)
  multipartkit.content_type(part) |> should.equal(Some("text/plain"))
  multipartkit.header(part, "content-type") |> should.equal(Ok("text/plain"))
  multipartkit.header(part, "x-missing") |> should.equal(Error(Nil))
  multipartkit.new_part(headers: [#("X-Note", "a\r\nb")], body: <<>>)
  |> should.equal(Error(InvalidHeaderValue("X-Note", "a\r\nb")))
}

pub fn infer_content_type_doc_test() {
  multipartkit.infer_content_type("photo.png", <<>>)
  |> should.equal("image/png")
  multipartkit.infer_content_type("blob", <<
    0x89,
    "PNG":utf8,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  >>)
  |> should.equal("image/png")
  multipartkit.infer_content_type("blob", <<0, 1, 2>>)
  |> should.equal("application/octet-stream")
}

pub fn parse_doc_test() {
  let body = <<
    "--b\r\n", "Content-Disposition: form-data; name=\"title\"\r\n\r\n",
    "hello\r\n", "--b--\r\n",
  >>
  let assert Ok(parts) =
    multipartkit.parse(
      body,
      "multipart/form-data; boundary=b",
      multipartkit.default_limits,
    )
  multipartkit.field(parts, "title") |> should.equal(Ok("hello"))
  multipartkit.parse(<<>>, "application/json", multipartkit.default_limits)
  |> should.equal(Error(UnsupportedMediaType("application/json")))
}

pub fn parse_content_disposition_doc_test() {
  multipartkit.parse_content_disposition("attachment; filename=\"a.txt\"")
  |> should.equal(
    Ok(
      ContentDisposition(
        disposition: "attachment",
        name: None,
        filename: Some("a.txt"),
        parameters: [#("filename", "a.txt")],
      ),
    ),
  )
  multipartkit.parse_content_disposition("; name=x")
  |> should.equal(Error(InvalidContentDisposition("; name=x")))
}

pub fn encode_doc_test() {
  let assert Ok(title) = multipartkit.new_field(name: "title", value: "hi")
  multipartkit.encode([title], "b")
  |> should.equal(
    Ok(<<
      "--b\r\n", "Content-Disposition: form-data; name=\"title\"\r\n\r\n",
      "hi\r\n", "--b--\r\n",
    >>),
  )
  multipartkit.encode([], "") |> should.equal(Error(InvalidBoundary("")))
}

pub fn stream_drain_body_doc_test() {
  let assert Ok(part) = multipartkit.new_field(name: "a", value: "hello")
  stream.drain_body(stream.body(stream.from_part(part)))
  |> should.equal(Ok(<<"hello">>))
  // The streamed encoding is the same bytes as `encode`.
  let assert Ok(expected) = multipartkit.encode([part], "b")
  stream.encode(yielder.single(stream.from_part(part)), "b")
  |> yielder.to_list
  |> result.all
  |> result.map(bit_array.concat)
  |> should.equal(Ok(expected))
}
