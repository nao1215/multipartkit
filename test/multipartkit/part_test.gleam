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
