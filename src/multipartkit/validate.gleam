import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import multipartkit/error.{
  type MultipartError, DisallowedContentType, PartTooLarge,
}
import multipartkit/internal/text
import multipartkit/part.{type Part}

/// Return `True` if any part is a text field with the given `name`.
pub fn has_field(parts: List(Part), name: String) -> Bool {
  list.any(parts, fn(p) {
    case p.name, p.filename {
      Some(value), None -> value == name
      _, _ -> False
    }
  })
}

/// Validate that the part body does not exceed `max` bytes.
pub fn max_file_size(the_part: Part, max: Int) -> Result(Part, MultipartError) {
  use <- bool.guard(
    when: bit_array.byte_size(the_part.body) > max,
    return: Error(PartTooLarge(max)),
  )
  Ok(the_part)
}

/// Validate that the part's `Content-Type` media type (case-insensitive)
/// belongs to `allowed`. Parameters on the part's Content-Type are ignored.
pub fn allowed_content_types(
  the_part: Part,
  allowed: List(String),
) -> Result(Part, MultipartError) {
  let actual = case the_part.content_type {
    Some(value) -> value
    None -> ""
  }
  let actual_media = strip_parameters(actual)
  case
    list.any(allowed, fn(candidate) {
      text.equals_ci(strip_parameters(candidate), actual_media)
    })
  {
    True -> Ok(the_part)
    False -> Error(DisallowedContentType(actual))
  }
}

fn strip_parameters(value: String) -> String {
  case string.split_once(value, on: ";") {
    Ok(#(media, _)) -> string.trim(media)
    Error(Nil) -> string.trim(value)
  }
}
