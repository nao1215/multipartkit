import gleeunit/should
import multipartkit

const ct = "multipart/form-data; boundary=ROUND"

pub fn parse_then_encode_then_parse_test() {
  let assert Ok(p1) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      body: <<"first":utf8>>,
    )
  let assert Ok(p2) =
    multipartkit.new_part(
      headers: [
        #("Content-Disposition", "form-data; name=\"b\"; filename=\"f.bin\""),
        #("Content-Type", "application/octet-stream"),
      ],
      body: <<0, 0xFE, 1, 2>>,
    )
  let parts = [p1, p2]
  let assert Ok(bytes) = multipartkit.encode(parts, "ROUND")
  let assert Ok(reparsed) =
    multipartkit.parse(bytes, ct, multipartkit.default_limits)
  reparsed |> should.equal(parts)
}

pub fn encode_canonical_then_parse_byte_identical_test() {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      body: <<"x":utf8>>,
    )
  let parts = [p]
  let assert Ok(first) = multipartkit.encode(parts, "ROUND")
  let assert Ok(reparsed) =
    multipartkit.parse(first, ct, multipartkit.default_limits)
  let assert Ok(second) = multipartkit.encode(reparsed, "ROUND")
  first |> should.equal(second)
}

pub fn empty_body_round_trip_test() {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "form-data; name=\"empty\"")],
      body: <<>>,
    )
  let parts = [p]
  let assert Ok(bytes) = multipartkit.encode(parts, "ROUND")
  let assert Ok(reparsed) =
    multipartkit.parse(bytes, ct, multipartkit.default_limits)
  reparsed |> should.equal(parts)
}
