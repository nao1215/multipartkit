//// Parse a synthetic incoming HTTP `multipart/form-data` request and pull
//// out a couple of fields plus a file. Mirrors what an HTTP framework
//// (mist, wisp, etc.) hands you: the raw body bytes plus the full
//// `Content-Type` header value.
////
////    cd examples/parse_request
////    gleam run

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import multipartkit
import multipartkit/error.{
  type MultipartError, BodyTooLarge, DisallowedContentType, HeaderTooLarge,
  InvalidUtf8Field, MissingField, MissingFile, PartTooLarge, TooManyParts,
}
import multipartkit/limit
import multipartkit/part.{type Part}
import multipartkit/query
import multipartkit/validate

pub type Upload {
  Upload(title: String, notes: String, avatar: Part)
}

pub fn main() {
  // Pretend a framework handed us these. The Content-Type is the FULL
  // header value, including the `boundary` parameter.
  let content_type =
    "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"
  let body = sample_body()

  case parse_upload(body, content_type) {
    Ok(upload) -> {
      io.println("title: " <> upload.title)
      io.println("notes: " <> upload.notes)
      io.println("avatar: " <> avatar_summary(upload.avatar))
    }
    Error(err) -> io.println("rejected request: " <> describe(err))
  }
}

/// Decode an `Upload` from the raw body and content-type produced by an
/// HTTP framework. Demonstrates how `parse_with_limits`, `query.required_*`,
/// and `validate` compose into a tidy `use <- result.try` pipeline.
pub fn parse_upload(
  body: BitArray,
  content_type: String,
) -> Result(Upload, MultipartError) {
  // Tighter limits than `default_limits()` for a public endpoint.
  // The values are hard-coded so the validated `new` is known to
  // succeed; production code with dynamic values should propagate
  // `LimitConfigError` through the result chain.
  let assert Ok(limits) =
    limit.new(
      max_body_bytes: 1_000_000,
      max_part_bytes: 200_000,
      max_parts: 10,
      max_header_bytes: 8192,
    )
  use parts <- result.try(multipartkit.parse_with_limits(
    body,
    content_type,
    limits,
  ))
  use title <- result.try(query.required_field(parts, "title"))
  use notes <- result.try(query.required_field(parts, "notes"))
  use avatar <- result.try(query.required_file(parts, "avatar"))
  use avatar <- result.try(validate.max_file_size(avatar, 50_000))
  use avatar <- result.try(
    validate.allowed_content_types(avatar, ["image/png", "image/jpeg"]),
  )
  Ok(Upload(title: title, notes: notes, avatar: avatar))
}

fn sample_body() -> BitArray {
  let dash =
    bit_array.from_string("------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n")
  let close =
    bit_array.from_string("------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n")
  bit_array.concat([
    dash,
    <<"Content-Disposition: form-data; name=\"title\"\r\n\r\n":utf8>>,
    <<"hello world\r\n":utf8>>,
    dash,
    <<"Content-Disposition: form-data; name=\"notes\"\r\n\r\n":utf8>>,
    <<"hand-rolled\r\n":utf8>>,
    dash,
    <<
      "Content-Disposition: form-data; name=\"avatar\"; filename=\"cat.png\"\r\n":utf8,
    >>,
    <<"Content-Type: image/png\r\n\r\n":utf8>>,
    <<137, 80, 78, 71, 13, 10, 26, 10, "\r\n":utf8>>,
    close,
  ])
}

fn avatar_summary(avatar: Part) -> String {
  let size = bit_array.byte_size(part.body(avatar))
  let filename = case part.filename(avatar) {
    Some(value) -> value
    None -> "(none)"
  }
  filename <> " (" <> int.to_string(size) <> " bytes)"
}

fn describe(err: MultipartError) -> String {
  case err {
    MissingField(name) -> "missing field: " <> name
    MissingFile(name) -> "missing file: " <> name
    InvalidUtf8Field(name) -> "field is not UTF-8: " <> name
    DisallowedContentType(actual) -> "disallowed content type: " <> actual
    PartTooLarge(_) -> "a part exceeded its size limit"
    BodyTooLarge(_) -> "the request body exceeded its size limit"
    HeaderTooLarge(_) -> "a header block was too large"
    TooManyParts(_) -> "too many parts"
    _ -> "request rejected"
  }
}
