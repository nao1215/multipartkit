//// Pick a file part's Content-Type with `infer_content_type`, which uses
//// `nao1215/mimetype` to look at the filename and then the leading bytes.
////
////    cd examples/mimetype_inference
////    gleam run

import gleam/io
import gleam/list
import gleam/option
import multipartkit

pub fn main() {
  let png = <<137, 80, 78, 71, 13, 10, 26, 10>>
  let files = [
    #("avatar", "cat.png", png),
    #("no_extension", "blob", png),
    #("unknown", "blob", <<0, 1, 2>>),
  ]
  let parts =
    list.map(files, fn(file) {
      let #(name, filename, body) = file
      let content_type = multipartkit.infer_content_type(filename, body)
      let assert Ok(part) =
        multipartkit.new_file(name:, filename:, content_type:, body:)
      part
    })

  let #(content_type, body) = multipartkit.encode_form(parts)
  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  list.each(parts, fn(part) {
    io.println(
      option.unwrap(multipartkit.filename(part), "")
      <> ": "
      <> option.unwrap(multipartkit.content_type(part), ""),
    )
  })
}
