import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import multipartkit/error.{
  type MultipartError, InvalidUtf8Field, MissingField, MissingFile,
}
import multipartkit/part.{type Part}

/// Return the body of the first text field with the given `name`, decoded as
/// UTF-8.
///
/// A part counts as a *text field* iff its `Content-Disposition` is
/// `form-data` with a `name` parameter and **no** `filename` parameter.
/// Parts whose `name` is `None` are skipped.
///
/// If the first matching text field exists but its body is not valid UTF-8,
/// `None` is returned. Use `required_field` if you need to distinguish
/// "missing" from "present but not UTF-8".
pub fn field(parts: List(Part), name: String) -> Option(String) {
  case find_text_field(parts, name) {
    None -> None
    Some(found_part) ->
      case bit_array.to_string(found_part.body) {
        Ok(value) -> Some(value)
        Error(Nil) -> None
      }
  }
}

/// Strict variant of `field`. Returns `MissingField` if no text field
/// matches; returns `InvalidUtf8Field` if the body is not valid UTF-8.
pub fn required_field(
  parts: List(Part),
  name: String,
) -> Result(String, MultipartError) {
  case find_text_field(parts, name) {
    None -> Error(MissingField(name))
    Some(found_part) ->
      case bit_array.to_string(found_part.body) {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error(InvalidUtf8Field(name))
      }
  }
}

/// Return all text fields with the given `name` in input order. Parts whose
/// body is not valid UTF-8 are silently skipped. For strict semantics,
/// iterate manually with `required_field`.
pub fn fields(parts: List(Part), name: String) -> List(String) {
  parts
  |> list.filter(fn(p) { is_text_field_named(p, name) })
  |> list.filter_map(fn(p) { bit_array.to_string(p.body) })
}

/// First file part with the given `name`. `filename = Some("")` still counts
/// as a file (the unselected `<input type="file">` case).
pub fn file(parts: List(Part), name: String) -> Option(Part) {
  case list.find(parts, fn(p) { is_file_named(p, name) }) {
    Ok(found_part) -> Some(found_part)
    Error(Nil) -> None
  }
}

/// Strict variant of `file`. Returns `MissingFile` if no file part matches.
pub fn required_file(
  parts: List(Part),
  name: String,
) -> Result(Part, MultipartError) {
  case file(parts, name) {
    Some(found_part) -> Ok(found_part)
    None -> Error(MissingFile(name))
  }
}

/// All file parts with the given `name` in input order.
pub fn files(parts: List(Part), name: String) -> List(Part) {
  list.filter(parts, fn(p) { is_file_named(p, name) })
}

/// Distinct field names preserving first-appearance order. Parts with
/// `name == None` are skipped.
pub fn names(parts: List(Part)) -> List(String) {
  collect_names(parts, [], [])
}

fn collect_names(
  remaining: List(Part),
  seen: List(String),
  acc: List(String),
) -> List(String) {
  case remaining {
    [] -> list.reverse(acc)
    [the_part, ..rest] ->
      case the_part.name {
        None -> collect_names(rest, seen, acc)
        Some(name) ->
          case list.contains(seen, name) {
            True -> collect_names(rest, seen, acc)
            False -> collect_names(rest, [name, ..seen], [name, ..acc])
          }
      }
  }
}

fn find_text_field(parts: List(Part), name: String) -> Option(Part) {
  case list.find(parts, fn(p) { is_text_field_named(p, name) }) {
    Ok(found_part) -> Some(found_part)
    Error(Nil) -> None
  }
}

fn is_text_field_named(the_part: Part, name: String) -> Bool {
  case the_part.name, the_part.filename {
    Some(value), None -> value == name
    _, _ -> False
  }
}

fn is_file_named(the_part: Part, name: String) -> Bool {
  case the_part.name, the_part.filename {
    Some(value), Some(_) -> value == name
    _, _ -> False
  }
}
