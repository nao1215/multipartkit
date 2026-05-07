import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/encoder
import multipartkit/parser
import multipartkit/part

const ct = "multipart/form-data; boundary=ROUND"

pub fn parse_then_encode_then_parse_test() {
  let assert Ok(p1) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"first":utf8>>,
    )
  let assert Ok(p2) =
    part.new(
      headers: [
        #("Content-Disposition", "form-data; name=\"b\"; filename=\"f.bin\""),
        #("Content-Type", "application/octet-stream"),
      ],
      name: Some("b"),
      filename: Some("f.bin"),
      content_type: Some("application/octet-stream"),
      body: <<0, 0xFE, 1, 2>>,
    )
  let parts = [p1, p2]
  let assert Ok(bytes) = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(bytes, ct)
  reparsed |> should.equal(parts)
}

pub fn encode_canonical_then_parse_byte_identical_test() {
  let assert Ok(p) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"x":utf8>>,
    )
  let parts = [p]
  let assert Ok(first) = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(first, ct)
  let assert Ok(second) = encoder.encode("ROUND", reparsed)
  first |> should.equal(second)
}

pub fn empty_body_round_trip_test() {
  let assert Ok(p) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"empty\"")],
      name: Some("empty"),
      filename: None,
      content_type: None,
      body: <<>>,
    )
  let parts = [p]
  let assert Ok(bytes) = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(bytes, ct)
  reparsed |> should.equal(parts)
}
