import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/encoder
import multipartkit/form
import multipartkit/parser
import multipartkit/part.{Part}

pub fn empty_form_test() {
  form.new()
  |> form.parts
  |> should.equal([])
}

pub fn add_field_appends_in_order_test() {
  let f =
    form.new()
    |> form.add_field("a", "1")
    |> form.add_field("b", "2")
  let parts = form.parts(f)
  case parts {
    [first, second] -> {
      first.name |> should.equal(Some("a"))
      first.body |> should.equal(<<"1":utf8>>)
      second.name |> should.equal(Some("b"))
      second.body |> should.equal(<<"2":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn add_file_sets_metadata_test() {
  let f =
    form.new()
    |> form.add_file("upload", "doc.pdf", "application/pdf", <<"%PDF":utf8>>)
  let assert [the_part] = form.parts(f)
  the_part.name |> should.equal(Some("upload"))
  the_part.filename |> should.equal(Some("doc.pdf"))
  the_part.content_type |> should.equal(Some("application/pdf"))
}

pub fn add_file_auto_falls_through_to_octet_stream_test() {
  // The default infer module returns None for both helpers in v0.1.0.
  let f =
    form.new()
    |> form.add_file_auto("blob", "any.bin", <<1, 2, 3>>)
  let assert [the_part] = form.parts(f)
  the_part.content_type |> should.equal(Some("application/octet-stream"))
}

pub fn unsafe_add_part_inserts_verbatim_test() {
  let manual =
    Part(
      headers: [#("X-Custom", "v")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"raw":utf8>>,
    )
  let f =
    form.new()
    |> form.unsafe_add_part(manual)
  let assert [the_part] = form.parts(f)
  the_part.headers |> should.equal([#("X-Custom", "v")])
  the_part.name |> should.equal(None)
}

pub fn form_round_trips_with_multiple_parts_test() {
  let f =
    form.new()
    |> form.add_field("name", "Alice")
    |> form.add_field("notes", "hello world")
    |> form.add_file("avatar", "a.png", "image/png", <<0x89, 0x50, 0x4E, 0x47>>)
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok(parts) = parser.parse(body, content_type)
  case parts {
    [first, second, third] -> {
      first.name |> should.equal(Some("name"))
      first.body |> should.equal(<<"Alice":utf8>>)
      second.name |> should.equal(Some("notes"))
      second.body |> should.equal(<<"hello world":utf8>>)
      third.name |> should.equal(Some("avatar"))
      third.filename |> should.equal(Some("a.png"))
      third.content_type |> should.equal(Some("image/png"))
      third.body |> should.equal(<<0x89, 0x50, 0x4E, 0x47>>)
    }
    _ -> should.fail()
  }
}

pub fn add_field_with_quote_in_value_round_trips_test() {
  // Quotes inside the field value go to the part body, not to a header.
  let f =
    form.new()
    |> form.add_field("k", "value with \" quote")
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok([p]) = parser.parse(body, content_type)
  p.body |> should.equal(<<"value with \" quote":utf8>>)
}
