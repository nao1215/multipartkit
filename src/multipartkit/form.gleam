import gleam/list
import gleam/option.{None, Some}
import gleam/string
import multipartkit/infer
import multipartkit/part.{type Part, Part}

/// Opaque builder for multipart/form-data messages.
///
/// `Form` is constructed via `new` and accumulated with `add_field` /
/// `add_file` / `add_file_auto` / `unsafe_add_part`. Read it back as
/// `List(Part)` via `parts`. The boundary is generated lazily by
/// `encode_form` and is not part of `Form`'s observable state.
pub opaque type Form {
  Form(reversed_parts: List(Part))
}

/// A new empty form.
pub fn new() -> Form {
  Form(reversed_parts: [])
}

/// Append a text field. `value` is encoded as UTF-8 in the part body. No
/// filename is set.
pub fn add_field(form: Form, name: String, value: String) -> Form {
  let disposition = #("Content-Disposition", "form-data; name=" <> quote(name))
  let new_part =
    Part(
      headers: [disposition],
      name: Some(name),
      filename: None,
      content_type: None,
      body: <<value:utf8>>,
    )
  push(form, new_part)
}

/// Append a file part with an explicit content type.
pub fn add_file(
  form: Form,
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Form {
  push(form, build_file_part(name, filename, content_type, body))
}

/// Append a file part, inferring the content type via `multipartkit/infer`.
///
/// The default `multipartkit/infer` returns `None` from both helpers in
/// v0.1.0, so this falls through to `application/octet-stream` unless the
/// host application has wired in an inferer. Inference precedence:
///
/// 1. `infer.content_type_from_filename(filename)`
/// 2. `infer.content_type_from_bytes(body)`
/// 3. `application/octet-stream`
pub fn add_file_auto(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
) -> Form {
  let content_type = case infer.content_type_from_filename(filename) {
    Some(value) -> value
    None ->
      case infer.content_type_from_bytes(body) {
        Some(value) -> value
        None -> "application/octet-stream"
      }
  }
  add_file(form, name, filename, content_type, body)
}

/// Append a pre-built `Part` without validation or normalisation.
///
/// The caller is responsible for keeping `headers`, `name`, `filename`, and
/// `content_type` mutually consistent. Prefer `add_field` / `add_file` /
/// `add_file_auto` for library-maintained consistency.
pub fn unsafe_add_part(form: Form, the_part: Part) -> Form {
  push(form, the_part)
}

/// Read the parts in insertion order.
pub fn parts(form: Form) -> List(Part) {
  list.reverse(form.reversed_parts)
}

fn push(form: Form, the_part: Part) -> Form {
  Form(reversed_parts: [the_part, ..form.reversed_parts])
}

fn build_file_part(
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Part {
  let disposition_header = #(
    "Content-Disposition",
    "form-data; name=" <> quote(name) <> "; filename=" <> quote(filename),
  )
  let content_type_header = #("Content-Type", content_type)
  Part(
    headers: [disposition_header, content_type_header],
    name: Some(name),
    filename: Some(filename),
    content_type: Some(content_type),
    body: body,
  )
}

fn quote(value: String) -> String {
  "\"" <> escape_quotes(value, "") <> "\""
}

fn escape_quotes(remaining: String, acc: String) -> String {
  case string.pop_grapheme(remaining) {
    Error(Nil) -> acc
    Ok(#("\\", rest)) -> escape_quotes(rest, acc <> "\\\\")
    Ok(#("\"", rest)) -> escape_quotes(rest, acc <> "\\\"")
    Ok(#(other, rest)) -> escape_quotes(rest, acc <> other)
  }
}
