import gleam/option.{None, Some}
import gleeunit/should
import multipartkit.{
  type Part, InvalidContentDisposition, InvalidHeaderName, InvalidHeaderValue,
}

fn sample() -> Part {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [
        #("Content-Disposition", "form-data; name=\"a\""),
        #("X-Trace", "first"),
        #("x-trace", "second"),
      ],
      body: <<>>,
    )
  p
}

pub fn header_finds_first_match_case_insensitively_test() {
  multipartkit.header(sample(), "X-TRACE") |> should.equal(Ok("first"))
}

pub fn header_returns_error_when_missing_test() {
  multipartkit.header(sample(), "Content-Type") |> should.equal(Error(Nil))
}

pub fn headers_keep_order_and_case_test() {
  multipartkit.headers(sample())
  |> should.equal([
    #("Content-Disposition", "form-data; name=\"a\""),
    #("X-Trace", "first"),
    #("x-trace", "second"),
  ])
}

pub fn header_lookup_uses_ascii_only_case_folding_test() {
  // Unicode lowercasing folds `İ` towards `i`; header names must not.
  let assert Ok(p) =
    multipartkit.new_part(headers: [#("x-custom-i", "value")], body: <<>>)
  multipartkit.header(p, "X-Custom-İ") |> should.equal(Error(Nil))
  multipartkit.header(p, "X-CUSTOM-I") |> should.equal(Ok("value"))
  // A header name is printable ASCII, so `İ` cannot be in one.
  multipartkit.new_part(headers: [#("X-Custom-İ", "value")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName("X-Custom-İ")))
}

pub fn new_part_rejects_header_breaking_values_test() {
  // #28: a value with CR or LF would add header lines on the wire.
  multipartkit.new_part(
    headers: [#("X-Foo", "good\nX-Injected: malicious")],
    body: <<>>,
  )
  |> should.equal(
    Error(InvalidHeaderValue("X-Foo", "good\nX-Injected: malicious")),
  )
  multipartkit.new_part(
    headers: [#("X-Foo", "good\r\nX-Injected: malicious")],
    body: <<>>,
  )
  |> should.equal(
    Error(InvalidHeaderValue("X-Foo", "good\r\nX-Injected: malicious")),
  )
  multipartkit.new_part(
    headers: [#("X-Foo", "good\u{0000}injected")],
    body: <<>>,
  )
  |> should.equal(Error(InvalidHeaderValue("X-Foo", "good\u{0000}injected")))
}

pub fn new_part_rejects_bad_header_names_test() {
  multipartkit.new_part(headers: [#("X-Foo\nX-Injected", "value")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName("X-Foo\nX-Injected")))
  // The parser splits at the first `:`.
  multipartkit.new_part(headers: [#("X-Foo: smuggled", "value")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName("X-Foo: smuggled")))
  // The parser rejects an empty name, so it could not round trip.
  multipartkit.new_part(headers: [#("", "value")], body: <<>>)
  |> should.equal(Error(InvalidHeaderName("")))
}

pub fn new_part_rejects_bad_content_disposition_test() {
  multipartkit.new_part(
    headers: [#("Content-Disposition", "; name=x")],
    body: <<>>,
  )
  |> should.equal(Error(InvalidContentDisposition("; name=x")))
}

pub fn new_part_trims_ows_test() {
  // #29: the parser trims spaces and tabs around values, so new_part does
  // too, and inner whitespace stays.
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [
        #("X-A", " spaced"),
        #("X-B", "spaced "),
        #("X-C", "\t value \t"),
        #("X-D", "  hello world  "),
      ],
      body: <<>>,
    )
  multipartkit.headers(p)
  |> should.equal([
    #("X-A", "spaced"),
    #("X-B", "spaced"),
    #("X-C", "value"),
    #("X-D", "hello world"),
  ])
}

pub fn new_part_reads_fields_from_headers_test() {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [
        #("content-disposition", "form-data; name=\"up\"; filename=\"a.bin\""),
        #("content-type", "application/octet-stream"),
      ],
      body: <<1>>,
    )
  multipartkit.name(p) |> should.equal(Some("up"))
  multipartkit.filename(p) |> should.equal(Some("a.bin"))
  multipartkit.content_type(p) |> should.equal(Some("application/octet-stream"))
}

pub fn attachment_part_has_no_name_test() {
  let assert Ok(p) =
    multipartkit.new_part(
      headers: [#("Content-Disposition", "attachment; filename=\"raw.bin\"")],
      body: <<>>,
    )
  multipartkit.name(p) |> should.equal(None)
  multipartkit.filename(p) |> should.equal(None)
}

pub fn part_without_headers_test() {
  let assert Ok(p) = multipartkit.new_part(headers: [], body: <<"x">>)
  multipartkit.name(p) |> should.equal(None)
  multipartkit.content_type(p) |> should.equal(None)
}

pub fn new_part_round_trips_equal_test() {
  // #27 and #29: a built part and the parsed copy compare equal with `==`.
  let assert Ok(original) =
    multipartkit.new_part(
      headers: [
        #("Content-Disposition", "form-data; name=\"a\""),
        #("X-Foo", " spaced"),
        #("X-Trace", "1"),
        #("X-Trace", "2"),
      ],
      body: <<"hello":utf8>>,
    )
  let assert Ok(wire) = multipartkit.encode([original], "BOUNDARY42")
  multipartkit.parse(
    wire,
    "multipart/form-data; boundary=BOUNDARY42",
    multipartkit.default_limits,
  )
  |> should.equal(Ok([original]))
}

pub fn parts_differ_when_header_order_differs_test() {
  let assert Ok(a) =
    multipartkit.new_part(
      headers: [#("X-Trace", "first"), #("X-Trace", "second")],
      body: <<>>,
    )
  let assert Ok(b) =
    multipartkit.new_part(
      headers: [#("X-Trace", "second"), #("X-Trace", "first")],
      body: <<>>,
    )
  should.not_equal(a, b)
}
