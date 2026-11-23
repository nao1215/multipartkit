//// Parse a `multipart/form-data` request body as an HTTP server receives
//// it: the raw body bytes and the full `Content-Type` header value.
////
////    cd examples/parse_request
////    gleam run

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option
import gleam/result
import gleam/string
import multipartkit.{type MultipartError, type Part}

pub type Upload {
  Upload(title: String, notes: String, avatar: Part)
}

pub fn main() {
  let content_type =
    "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"

  case parse_upload(sample_body(), content_type) {
    Ok(upload) -> {
      io.println("title: " <> upload.title)
      io.println("notes: " <> upload.notes)
      io.println("avatar: " <> avatar_summary(upload.avatar))
    }
    Error(error) -> io.println("rejected request: " <> string.inspect(error))
  }
}

/// Reads the fields of an upload form, with tighter limits than
/// `default_limits` for a public endpoint.
pub fn parse_upload(
  body: BitArray,
  content_type: String,
) -> Result(Upload, MultipartError) {
  let limits =
    multipartkit.Limits(
      max_body_bytes: 1_000_000,
      max_part_bytes: 200_000,
      max_parts: 10,
      max_header_bytes: 8192,
    )
  use parts <- result.try(multipartkit.parse(body, content_type, limits))
  use title <- result.try(multipartkit.field(parts, "title"))
  use notes <- result.try(multipartkit.field(parts, "notes"))
  use avatar <- result.try(multipartkit.file(parts, "avatar"))
  use avatar <- result.try(
    multipartkit.allowed_content_types(avatar, ["image/png", "image/jpeg"]),
  )
  Ok(Upload(title:, notes:, avatar:))
}

fn sample_body() -> BitArray {
  let delimiter = <<"------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n":utf8>>
  <<
    delimiter:bits,
    "Content-Disposition: form-data; name=\"title\"\r\n\r\n":utf8,
    "hello world\r\n":utf8, delimiter:bits,
    "Content-Disposition: form-data; name=\"notes\"\r\n\r\n":utf8,
    "hand-rolled\r\n":utf8, delimiter:bits,
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"cat.png\"\r\n":utf8,
    "Content-Type: image/png\r\n\r\n":utf8, 137, 80, 78, 71, 13, 10, 26, 10,
    "\r\n":utf8, "------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n":utf8,
  >>
}

fn avatar_summary(avatar: Part) -> String {
  let size = bit_array.byte_size(multipartkit.body(avatar))
  option.unwrap(multipartkit.filename(avatar), "(none)")
  <> " ("
  <> int.to_string(size)
  <> " bytes)"
}
