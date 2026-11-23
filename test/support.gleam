//// Helpers that build part lists in tests.

import gleam/list
import multipartkit.{type Part}

/// Appends a text field, failing the test when `new_field` rejects it.
pub fn add_field(
  parts: List(Part),
  name name: String,
  value value: String,
) -> List(Part) {
  let assert Ok(part) = multipartkit.new_field(name:, value:)
  list.append(parts, [part])
}

/// Appends a file part, failing the test when `new_file` rejects it.
pub fn add_file(
  parts: List(Part),
  name name: String,
  filename filename: String,
  content_type content_type: String,
  body body: BitArray,
) -> List(Part) {
  let assert Ok(part) =
    multipartkit.new_file(name:, filename:, content_type:, body:)
  list.append(parts, [part])
}
