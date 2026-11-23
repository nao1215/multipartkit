import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option
import multipartkit

pub fn main() {
  let assert Ok(title) = multipartkit.new_field(name: "title", value: "hello")
  let assert Ok(avatar) =
    multipartkit.new_file(
      name: "avatar",
      filename: "cat.png",
      content_type: "image/png",
      body: <<137, 80, 78, 71>>,
    )
  let #(content_type, body) = multipartkit.encode_form([title, avatar])

  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  let assert Ok(title) = multipartkit.field(parts, "title")
  let assert Ok(avatar) = multipartkit.file(parts, "avatar")

  io.println("Content-Type: " <> content_type)
  io.println("title=" <> title)
  io.println(
    "avatar filename=" <> option.unwrap(multipartkit.filename(avatar), ""),
  )
  let size = bit_array.byte_size(multipartkit.body(avatar))
  io.println("avatar size=" <> int.to_string(size))
}
