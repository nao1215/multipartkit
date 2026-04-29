import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/encoder
import multipartkit/parser
import multipartkit/part.{Part}

const ct = "multipart/form-data; boundary=ROUND"

pub fn parse_then_encode_then_parse_test() {
  let parts = [
    Part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"first":utf8>>,
    ),
    Part(
      headers: [
        #("Content-Disposition", "form-data; name=\"b\"; filename=\"f.bin\""),
        #("Content-Type", "application/octet-stream"),
      ],
      name: Some("b"),
      filename: Some("f.bin"),
      content_type: Some("application/octet-stream"),
      body: <<0, 0xFE, 1, 2>>,
    ),
  ]
  let bytes = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(bytes, ct)
  reparsed |> should.equal(parts)
}

pub fn encode_canonical_then_parse_byte_identical_test() {
  let parts = [
    Part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"x":utf8>>,
    ),
  ]
  let first = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(first, ct)
  let second = encoder.encode("ROUND", reparsed)
  first |> should.equal(second)
}

pub fn empty_body_round_trip_test() {
  let parts = [
    Part(
      headers: [#("Content-Disposition", "form-data; name=\"empty\"")],
      name: Some("empty"),
      filename: None,
      content_type: None,
      body: <<>>,
    ),
  ]
  let bytes = encoder.encode("ROUND", parts)
  let assert Ok(reparsed) = parser.parse(bytes, ct)
  reparsed |> should.equal(parts)
}
