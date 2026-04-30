import gleam/io
import gleam/option.{None, Some}
import multipartkit
import multipartkit/form
import multipartkit/part
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
  case part.filename(avatar) {
    Some(filename) -> io.println("avatar filename=" <> filename)
    None -> io.println("avatar has no filename")
  }
}
