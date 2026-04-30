//// Wire `nao1215/mimetype` into multipartkit's pluggable `Inferer` so
//// `add_file_auto_with` can infer the right `Content-Type` from a
//// filename or from the file's leading bytes.
////
////    cd examples/mimetype_inference
////    gleam run

import gleam/io
import gleam/option.{type Option, None, Some}
import mimetype
import multipartkit
import multipartkit/form.{type Form}
import multipartkit/infer.{type Inferer, Inferer}
import multipartkit/part

pub fn main() {
  let inferer = mimetype_inferer()
  let form_value =
    form.new()
    |> form.add_file_auto_with(
      "avatar",
      "cat.png",
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      inferer,
    )
    |> form.add_file_auto_with(
      "no_extension",
      "blob",
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      inferer,
    )

  list_each(form.parts(form_value), describe_part)

  // Round-trip through encode_form and parse to demonstrate the inferred
  // Content-Type survives the wire.
  let #(content_type, body) = multipartkit.encode_form(form_value)
  let assert Ok(parts) = multipartkit.parse(body, content_type)
  io.println("\nAfter round-trip:")
  list_each(parts, describe_part)
}

/// Build an `Inferer` that delegates to `nao1215/mimetype`.
///
/// `mimetype` returns its results as `MimeType` values (an opaque type
/// since 0.8.0); `multipartkit/infer.Inferer` wants `String`. The
/// adapters below run each candidate through `mimetype.to_string`
/// before handing it back to multipartkit.
pub fn mimetype_inferer() -> Inferer {
  let from_filename = fn(name: String) -> Option(String) {
    case mimetype.filename_to_mime_type_strict(name) {
      Ok(value) -> Some(mimetype.to_string(value))
      Error(_) -> None
    }
  }
  let from_bytes = fn(body: BitArray) -> Option(String) {
    case mimetype.detect_strict(body) {
      Ok(value) -> Some(mimetype.to_string(value))
      Error(_) -> None
    }
  }
  Inferer(from_filename: from_filename, from_bytes: from_bytes)
}

/// Convenience helper used by `main` to demonstrate that the inferer also
/// works for an arbitrary filename + bytes pair.
pub fn add_file_auto_with_mimetype(
  form_value: Form,
  name: String,
  filename: String,
  body: BitArray,
) -> Form {
  form.add_file_auto_with(form_value, name, filename, body, mimetype_inferer())
}

fn describe_part(the_part: part.Part) -> Nil {
  let name = case part.name(the_part) {
    Some(value) -> value
    None -> "(none)"
  }
  let filename = case part.filename(the_part) {
    Some(value) -> value
    None -> "(none)"
  }
  let content_type = case part.content_type(the_part) {
    Some(value) -> value
    None -> "(none)"
  }
  io.println(
    "- name="
      <> name
      <> " filename="
      <> filename
      <> " content_type="
      <> content_type,
  )
}

fn list_each(items: List(a), apply: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      apply(first)
      list_each(rest, apply)
    }
  }
}
