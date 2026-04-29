//// Quick-start example for `multipartkit`.
////
//// Build a `multipart/form-data` body, encode it with a freshly generated
//// boundary, and parse it back. Run with:
////
////    cd examples/quick_start
////    gleam run

import gleam/io
import gleam/option.{None, Some}
import multipartkit
import multipartkit/form
import multipartkit/query

pub fn main() {
  let request_form =
    form.new()
    |> form.add_field("title", "hello")
    |> form.add_file("avatar", "cat.png", "image/png", <<137, 80, 78, 71>>)

  let #(content_type, body) = multipartkit.encode_form(request_form)

  let assert Ok(parts) = multipartkit.parse(body, content_type)
  let assert Ok(title) = query.required_field(parts, "title")
  let assert Ok(avatar) = query.required_file(parts, "avatar")

  io.println("Content-Type: " <> content_type)
  io.println("title=" <> title)
  case avatar.filename {
    Some(filename) -> io.println("avatar filename=" <> filename)
    None -> io.println("avatar has no filename")
  }
}
