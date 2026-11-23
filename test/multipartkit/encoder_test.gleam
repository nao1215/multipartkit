import gleam/bit_array
import gleam/option.{Some}
import gleam/string
import gleam/yielder
import gleeunit/should
import multipartkit
import multipartkit/stream
import support

pub fn encode_zero_parts_test() {
  let assert Ok(body) = multipartkit.encode([], "B")
  body |> should.equal(<<"--B--\r\n":utf8>>)
}

pub fn encode_single_field_test() {
  let assert Ok(part_value) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      body: <<"hi":utf8>>,
    )
  let assert Ok(body) = multipartkit.encode([part_value], "B")
  body
  |> should.equal(<<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhi\r\n--B--\r\n":utf8,
  >>)
}

pub fn encode_emits_headers_verbatim_test() {
  // The encoder should not synthesize headers; it should emit exactly what
  // we pass.
  let assert Ok(part_value) =
    multipartkit.new_part(
      headers: [#("X-First", "1"), #("X-Second", "two")],
      body: <<"body":utf8>>,
    )
  let assert Ok(body) = multipartkit.encode([part_value], "B")
  body
  |> should.equal(<<
    "--B\r\nX-First: 1\r\nX-Second: two\r\n\r\nbody\r\n--B--\r\n":utf8,
  >>)
}

pub fn encode_form_produces_full_content_type_test() {
  let form_value =
    []
    |> support.add_field("k", "v")
  let #(content_type, _body) = multipartkit.encode_form(form_value)
  case string.starts_with(content_type, "multipart/form-data; boundary=") {
    True -> Nil
    False -> should.fail()
  }
}

pub fn encode_form_round_trips_test() {
  let form_value =
    []
    |> support.add_field("title", "ok")
    |> support.add_file("data", "x.bin", "application/octet-stream", <<
      1,
      2,
      3,
      4,
    >>)
  let #(content_type, body) = multipartkit.encode_form(form_value)
  let assert Ok([title_part, data_part]) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  multipartkit.name(title_part) |> should.equal(Some("title"))
  multipartkit.body(title_part) |> should.equal(<<"ok":utf8>>)
  multipartkit.filename(data_part) |> should.equal(Some("x.bin"))
  multipartkit.content_type(data_part)
  |> should.equal(Some("application/octet-stream"))
  multipartkit.body(data_part) |> should.equal(<<1, 2, 3, 4>>)
}

pub fn encode_form_generates_fresh_boundary_test() {
  let form_value =
    []
    |> support.add_field("k", "v")
  let #(ct1, _) = multipartkit.encode_form(form_value)
  let #(ct2, _) = multipartkit.encode_form(form_value)
  // Two calls must produce different content-types (different boundaries).
  case ct1 == ct2 {
    True -> should.fail()
    False -> Nil
  }
}

pub fn encode_stream_round_trips_via_buffer_test() {
  let assert Ok(part0) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      body: <<"v":utf8>>,
    )
  let stream_part = stream.from_part(part0)
  let chunks = stream.encode(yielder.from_list([stream_part]), "B")
  // Drain — assert all items are Ok and concatenated body parses.
  let combined = drain_all(chunks, <<>>)
  case combined {
    Ok(bytes) -> {
      let assert Ok([parsed]) =
        multipartkit.parse(
          bytes,
          "multipart/form-data; boundary=B",
          multipartkit.default_limits,
        )
      multipartkit.name(parsed) |> should.equal(Some("a"))
      multipartkit.body(parsed) |> should.equal(<<"v":utf8>>)
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
