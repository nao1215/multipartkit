//// `infer_content_type` tries the extension, then the leading bytes, then
//// falls back to application/octet-stream (#59).

import gleam/list
import gleeunit/should
import multipartkit

const png = <<0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a>>

pub fn known_extensions_test() {
  list.each(
    [
      #("a.png", "image/png"),
      #("a.jpg", "image/jpeg"),
      #("a.jpeg", "image/jpeg"),
      #("a.gif", "image/gif"),
      #("a.pdf", "application/pdf"),
      #("a.json", "application/json"),
      #("a.txt", "text/plain"),
      #("a.csv", "text/csv"),
      #("a.html", "text/html"),
    ],
    fn(entry) {
      multipartkit.infer_content_type(entry.0, <<>>)
      |> should.equal(entry.1)
    },
  )
}

pub fn magic_bytes_when_extension_unknown_test() {
  list.each(
    [
      #(png, "image/png"),
      #(<<0xff, 0xd8, 0xff, 0xe0>>, "image/jpeg"),
      #(<<"%PDF-1.4":utf8>>, "application/pdf"),
      #(<<"GIF87a":utf8>>, "image/gif"),
    ],
    fn(entry) {
      multipartkit.infer_content_type("a.zzznosuch", entry.0)
      |> should.equal(entry.1)
    },
  )
}

pub fn extension_wins_over_bytes_test() {
  multipartkit.infer_content_type("a.pdf", png)
  |> should.equal("application/pdf")
}

pub fn fallback_test() {
  multipartkit.infer_content_type("", <<>>)
  |> should.equal("application/octet-stream")
  multipartkit.infer_content_type("blob", <<0, 1, 2>>)
  |> should.equal("application/octet-stream")
}

pub fn printable_text_is_text_plain_test() {
  multipartkit.infer_content_type("blob", <<"hello":utf8>>)
  |> should.equal("text/plain")
}
