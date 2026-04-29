import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/part.{type Part, Part}

fn sample() -> Part {
  Part(
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

pub fn header_lookup_uses_ascii_only_case_folding_test() {
  // Locale-sensitive lowercase folds Turkish I-with-dot to a lowercase i, but
  // ASCII case-insensitive comparison should not. Make sure non-ASCII names
  // do not collide with their Unicode-folded ASCII form.
  let dotless = "X-Custom-İ"
  // Add a part with a header named like that and look up "x-custom-i"; they
  // must NOT match.
  let p =
    Part(
      headers: [#(dotless, "value")],
      name: None,
      filename: None,
      content_type: None,
      body: <<>>,
    )
  part.header(p, "x-custom-i") |> should.equal(None)
}
