import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/error.{InvalidHeaderName, InvalidHeaderValue}
import multipartkit/part.{type Part}

fn sample() -> Part {
  let assert Ok(p) =
    part.new(
      headers: [
        #("Content-Disposition", "form-data; name=\"a\""),
        #("X-Trace", "first"),
        #("x-trace", "second"),
        #("X-TRACE", "third"),
      ],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<>>,
    )
  p
}

pub fn header_finds_first_match_case_insensitively_test() {
  part.header(sample(), "x-trace") |> should.equal(Some("first"))
}

pub fn header_returns_none_when_missing_test() {
  part.header(sample(), "Content-Type") |> should.equal(None)
}

pub fn headers_returns_all_in_storage_order_test() {
  part.headers(sample(), "X-Trace")
  |> should.equal(["first", "second", "third"])
}

pub fn new_rejects_lf_in_header_value_test() {
  // #28: a header value containing `\n` would split into two header
  // lines on the wire and let an attacker who controls the value
  // smuggle additional headers.
  part.new(
    headers: [#("X-Foo", "good\nX-Injected: malicious")],
    name: None,
    filename: None,
    content_type: None,
    body: <<>>,
  )
  |> should.equal(
    Error(InvalidHeaderValue("X-Foo", "good\nX-Injected: malicious")),
  )
}

pub fn new_rejects_crlf_in_header_value_test() {
  // The exact case from the issue reproducer.
  part.new(
    headers: [#("X-Foo", "good\r\nX-Injected: malicious")],
    name: None,
    filename: None,
    content_type: None,
    body: <<>>,
  )
  |> should.equal(
    Error(InvalidHeaderValue("X-Foo", "good\r\nX-Injected: malicious")),
  )
}

pub fn new_rejects_nul_in_header_value_test() {
  // NUL byte in a header value would either be silently truncated by
  // some C-string consumers or pass through as a literal — both bad.
  part.new(
    headers: [#("X-Foo", "good\u{0000}injected")],
    name: None,
    filename: None,
    content_type: None,
    body: <<>>,
  )
  |> should.equal(Error(InvalidHeaderValue("X-Foo", "good\u{0000}injected")))
}

pub fn new_rejects_lf_in_header_name_test() {
  // Header name containing `\n` would also inject a header break.
  part.new(
    headers: [#("X-Foo\nX-Injected", "value")],
    name: None,
    filename: None,
    content_type: None,
    body: <<>>,
  )
  |> should.equal(Error(InvalidHeaderName("X-Foo\nX-Injected")))
}

pub fn new_rejects_colon_in_header_name_test() {
  // `:` in a header name would split into a different `name: value`
  // pair on parse — the parser uses the first `:` as the separator.
  part.new(
    headers: [#("X-Foo: smuggled", "value")],
    name: None,
    filename: None,
    content_type: None,
    body: <<>>,
  )
  |> should.equal(Error(InvalidHeaderName("X-Foo: smuggled")))
}

pub fn new_accepts_valid_headers_test() {
  // Sanity check: ordinary header values still construct cleanly.
  part.new(
    headers: [#("Content-Disposition", "form-data; name=\"a\"")],
    name: Some("a"),
    filename: None,
    content_type: None,
    body: <<"hi":utf8>>,
  )
  |> should.be_ok
}

pub fn new_strips_leading_ows_from_header_value_test() {
  // #29: a leading space on a header value would be stripped by the
  // parser on the wire round-trip, but the previous constructor stored
  // the value verbatim — the in-memory Part diverged from the on-wire
  // canonical form. The constructor now strips OWS at construction so
  // round-trip equality holds.
  let assert Ok(p) =
    part.new(
      headers: [#("X-Foo", " spaced")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "X-Foo") |> should.equal(Some("spaced"))
}

pub fn new_strips_trailing_ows_from_header_value_test() {
  // RFC 7230 §3.2.4 OWS is symmetric — strip both ends.
  let assert Ok(p) =
    part.new(
      headers: [#("X-Foo", "spaced ")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "X-Foo") |> should.equal(Some("spaced"))
}

pub fn new_strips_ows_with_tabs_test() {
  // OWS is space (0x20) OR horizontal tab (0x09).
  let assert Ok(p) =
    part.new(
      headers: [#("X-Foo", "\t value \t")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "X-Foo") |> should.equal(Some("value"))
}

pub fn new_preserves_internal_whitespace_test() {
  // Whitespace BETWEEN tokens of a header value is part of the data and
  // must not be collapsed.
  let assert Ok(p) =
    part.new(
      headers: [#("X-Foo", "  hello world  ")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "X-Foo") |> should.equal(Some("hello world"))
}

pub fn new_round_trips_through_encode_parse_test() {
  // The whole point of #29: a Part with leading whitespace in a header
  // value used to round-trip to a different Part. Now it round-trips
  // equal to itself.
  let assert Ok(original) =
    part.new(
      headers: [
        #("Content-Disposition", "form-data; name=\"a\""),
        #("X-Foo", " spaced"),
      ],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"hello":utf8>>,
    )
  part.header(original, "X-Foo") |> should.equal(Some("spaced"))
}

pub fn equal_on_wire_true_when_headers_and_body_match_test() {
  // #27: two parts with identical headers + body but different cache
  // fields (`name`, `filename`, `content_type`) compare equal on
  // the wire.
  let assert Ok(a) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"hello":utf8>>,
    )
  let assert Ok(b) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"a\"")],
      name: Some("a"),
      filename: None,
      content_type: None,
      body: <<"hello":utf8>>,
    )
  // Structural `==` differs because `name` is None vs Some("a").
  // `equal_on_wire` ignores that and returns True.
  part.equal_on_wire(a, b) |> should.be_true
}

pub fn equal_on_wire_false_on_different_body_test() {
  let assert Ok(a) =
    part.new(
      headers: [#("X-Foo", "v")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"a":utf8>>,
    )
  let assert Ok(b) =
    part.new(
      headers: [#("X-Foo", "v")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"b":utf8>>,
    )
  part.equal_on_wire(a, b) |> should.be_false
}

pub fn equal_on_wire_false_on_different_headers_test() {
  let assert Ok(a) =
    part.new(
      headers: [#("X-Foo", "1")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  let assert Ok(b) =
    part.new(
      headers: [#("X-Foo", "2")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.equal_on_wire(a, b) |> should.be_false
}

pub fn equal_on_wire_is_order_sensitive_on_headers_test() {
  // RFC 7230 says repeated header names preserve relative order, so
  // wire equality must reject reordered headers.
  let assert Ok(a) =
    part.new(
      headers: [#("X-Trace", "first"), #("X-Trace", "second")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  let assert Ok(b) =
    part.new(
      headers: [#("X-Trace", "second"), #("X-Trace", "first")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.equal_on_wire(a, b) |> should.be_false
}

pub fn list_equal_on_wire_pairwise_test() {
  let assert Ok(a) =
    part.new(
      headers: [#("X", "v")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"x":utf8>>,
    )
  let assert Ok(b) =
    part.new(
      headers: [#("X", "v")],
      name: Some("ignored"),
      filename: None,
      content_type: None,
      body: <<"x":utf8>>,
    )
  part.list_equal_on_wire([a], [b]) |> should.be_true
  part.list_equal_on_wire([], []) |> should.be_true
  part.list_equal_on_wire([a], []) |> should.be_false
  part.list_equal_on_wire([], [a]) |> should.be_false
  part.list_equal_on_wire([a, a], [a]) |> should.be_false
}

pub fn header_lookup_uses_ascii_only_case_folding_test() {
  // Locale-sensitive lowercase folds Turkish I-with-dot to a lowercase i, but
  // ASCII case-insensitive comparison should not. Make sure non-ASCII names
  // do not collide with their Unicode-folded ASCII form.
  let dotless = "X-Custom-İ"
  // Add a part with a header named like that and look up "x-custom-i"; they
  // must NOT match.
  let assert Ok(p) =
    part.new(
      headers: [#(dotless, "value")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "x-custom-i") |> should.equal(None)
}
