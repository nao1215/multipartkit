import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import gleeunit/should
import multipartkit/encoder
import multipartkit/form
import multipartkit/parser
import multipartkit/part
import multipartkit/stream

pub fn encode_zero_parts_test() {
  let assert Ok(body) = encoder.encode("B", [])
  body |> should.equal(<<"--B--\r\n":utf8>>)
}

pub fn encode_single_field_test() {
  let assert Ok(part_value) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"hi":utf8>>,
    )
  let assert Ok(body) = encoder.encode("B", [part_value])
  body
  |> should.equal(<<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhi\r\n--B--\r\n":utf8,
  >>)
}

pub fn encode_emits_headers_verbatim_test() {
  // The encoder should not synthesize headers; it should emit exactly what
  // we pass.
  let assert Ok(part_value) =
    part.new(
      headers: [#("X-First", "1"), #("X-Second", "two")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"body":utf8>>,
    )
  let assert Ok(body) = encoder.encode("B", [part_value])
  body
  |> should.equal(<<
    "--B\r\nX-First: 1\r\nX-Second: two\r\n\r\nbody\r\n--B--\r\n":utf8,
  >>)
}

pub fn encode_form_produces_full_content_type_test() {
  let form_value =
    form.new()
    |> form.add_field("k", "v")
  let #(content_type, _body) = encoder.encode_form(form_value)
  case string.starts_with(content_type, "multipart/form-data; boundary=") {
    True -> Nil
    False -> should.fail()
  }
}

pub fn encode_form_round_trips_test() {
  let form_value =
    form.new()
    |> form.add_field("title", "ok")
    |> form.add_file("data", "x.bin", "application/octet-stream", <<1, 2, 3, 4>>)
  let #(content_type, body) = encoder.encode_form(form_value)
  let assert Ok([title_part, data_part]) = parser.parse(body, content_type)
  part.name(title_part) |> should.equal(Some("title"))
  part.body(title_part) |> should.equal(<<"ok":utf8>>)
  part.filename(data_part) |> should.equal(Some("x.bin"))
  part.content_type(data_part) |> should.equal(Some("application/octet-stream"))
  part.body(data_part) |> should.equal(<<1, 2, 3, 4>>)
}

pub fn encode_form_generates_fresh_boundary_test() {
  let form_value =
    form.new()
    |> form.add_field("k", "v")
  let #(ct1, _) = encoder.encode_form(form_value)
  let #(ct2, _) = encoder.encode_form(form_value)
  // Two calls must produce different content-types (different boundaries).
  case ct1 == ct2 {
    True -> should.fail()
    False -> Nil
  }
}

pub fn encode_stream_round_trips_via_buffer_test() {
  let assert Ok(part0) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"v":utf8>>,
    )
  let stream_part = stream.from_part(part0)
  let chunks = encoder.encode_stream("B", yielder.from_list([stream_part]))
  // Drain — assert all items are Ok and concatenated body parses.
  let combined = drain_all(chunks, <<>>)
  case combined {
    Ok(bytes) -> {
      let assert Ok([parsed]) =
        parser.parse(bytes, "multipart/form-data; boundary=B")
      part.name(parsed) |> should.equal(Some("a"))
      part.body(parsed) |> should.equal(<<"v":utf8>>)
    }
    Error(_) -> should.fail()
  }
}

fn drain_all(
  source: yielder.Yielder(Result(BitArray, e)),
  acc: BitArray,
) -> Result(BitArray, e) {
  case yielder.step(source) {
    yielder.Done -> Ok(acc)
    yielder.Next(Ok(chunk), rest) ->
      drain_all(rest, bit_array.append(acc, chunk))
    yielder.Next(Error(err), _) -> Error(err)
  }
}
