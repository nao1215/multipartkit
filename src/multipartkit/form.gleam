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
///
/// Carriage returns, line feeds, and NUL bytes in `name` are silently
/// stripped to prevent header injection. The cached `name` on the resulting
/// `Part` reflects the sanitized value, matching what a parse-after-encode
/// round-trip would produce. Use `unsafe_add_part` if byte-exact
/// preservation is required.
pub fn add_field(form: Form, name: String, value: String) -> Form {
  let safe_name = sanitize_value(name)
  let disposition = #(
    "Content-Disposition",
    "form-data; name=" <> quote(safe_name),
  )
  let new_part =
    Part(
      headers: [disposition],
      name: Some(safe_name),
      filename: None,
      content_type: None,
      body: <<value:utf8>>,
    )
  push(form, new_part)
}

/// Append a file part with an explicit content type.
///
/// Carriage returns, line feeds, and NUL bytes in `name`, `filename`, and
/// `content_type` are silently stripped to prevent header injection. The
/// cached `name`, `filename`, and `content_type` on the resulting `Part`
/// reflect the sanitized values. Use `unsafe_add_part` if byte-exact
/// preservation is required.
pub fn add_file(
  form: Form,
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Form {
  push(form, build_file_part(name, filename, content_type, body))
}

/// Append a file part using the default (no-op) inferer.
///
/// Equivalent to `add_file_auto_with(form, name, filename, body,
/// infer.default_inferer())`. The default inferer returns `None` from both
/// helpers in v0.1.0, so this falls through to `application/octet-stream`
/// unless you call `add_file_auto_with` with a real inferer.
pub fn add_file_auto(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
) -> Form {
  add_file_auto_with(form, name, filename, body, infer.default_inferer())
}

/// Append a file part, inferring the content type via the supplied
/// `Inferer`.
///
/// Inference precedence:
///
/// 1. `inferer.from_filename(filename)`
/// 2. `inferer.from_bytes(body)`
/// 3. `application/octet-stream`
///
/// The inferred content type is sanitized (CR / LF / NUL stripped) before
/// being written to the header.
pub fn add_file_auto_with(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
  inferer: infer.Inferer,
) -> Form {
  let content_type = case inferer.from_filename(filename) {
    Some(value) -> value
    None ->
      case inferer.from_bytes(body) {
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
  let safe_name = sanitize_value(name)
  let safe_filename = sanitize_value(filename)
  let safe_content_type = sanitize_value(content_type)
  let disposition_header = #(
    "Content-Disposition",
    "form-data; name="
      <> quote(safe_name)
      <> "; filename="
      <> quote(safe_filename),
  )
  let content_type_header = #("Content-Type", safe_content_type)
  Part(
    headers: [disposition_header, content_type_header],
    name: Some(safe_name),
    filename: Some(safe_filename),
    content_type: Some(safe_content_type),
    body: body,
  )
}

/// Strip CR, LF, and NUL from `value`. Used to neutralise header injection
/// in any value that ends up on a header line — `name`, `filename`, and
/// `content_type`.
fn sanitize_value(value: String) -> String {
  value
  |> string.replace(each: "\r\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\u{0000}", with: "")
}

fn quote(value: String) -> String {
  "\"" <> escape_quoted(value, "") <> "\""
}

fn escape_quoted(remaining: String, acc: String) -> String {
  case string.pop_grapheme(remaining) {
    Error(Nil) -> acc
    Ok(#("\\", rest)) -> escape_quoted(rest, acc <> "\\\\")
    Ok(#("\"", rest)) -> escape_quoted(rest, acc <> "\\\"")
    Ok(#(other, rest)) -> escape_quoted(rest, acc <> other)
  }
}
