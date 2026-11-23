//// Regression tests for #51 and #57: `new_field` and `new_file` reject an
//// empty or whitespace-only field name, which RFC 7578 §4.2 does not allow.

import gleam/list
import gleeunit/should
import multipartkit.{EmptyFieldName}

pub fn new_field_rejects_blank_names_test() {
  list.each(["", "   ", "\t\t", "\n", "\r\n"], fn(name) {
    multipartkit.new_field(name:, value: "value")
    |> should.equal(Error(EmptyFieldName(name)))
  })
}

pub fn new_file_rejects_blank_names_test() {
  list.each(["", "  "], fn(name) {
    multipartkit.new_file(
      name:,
      filename: "file.txt",
      content_type: "text/plain",
      body: <<"hi">>,
    )
    |> should.equal(Error(EmptyFieldName(name)))
  })
}

pub fn new_file_allows_empty_filename_test() {
  // Only `name` is required; a browser sends an empty filename for a file
  // input left empty.
  let assert Ok(part) =
    multipartkit.new_file(
      name: "upload",
      filename: "",
      content_type: "application/octet-stream",
      body: <<>>,
    )
  let #(content_type, body) = multipartkit.encode_form([part])
  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  parts |> should.equal([part])
}
