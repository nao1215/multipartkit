import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/yielder.{type Yielder}
import multipartkit/error.{type MultipartError}
import multipartkit/form.{type Form}
import multipartkit/part.{type Part}
import multipartkit/stream.{type StreamPart}

/// Encode parts using the supplied boundary.
///
/// The boundary must satisfy the RFC 2046 grammar; otherwise the resulting
/// message will be invalid. To keep this function pure and total, the encoder
/// does not validate the boundary.
pub fn encode(boundary: String, parts: List(Part)) -> BitArray {
  let dash = <<"--":utf8>>
  let crlf = <<"\r\n":utf8>>
  let boundary_bytes = bit_array.from_string(boundary)
  let initial = <<>>
  let body =
    list.fold(parts, initial, fn(acc, the_part) {
      let header_block = build_header_block(part.all_headers(the_part))
      bit_array.concat([
        acc,
        dash,
        boundary_bytes,
        crlf,
        header_block,
        crlf,
        part.body(the_part),
        crlf,
      ])
    })
  bit_array.concat([body, dash, boundary_bytes, dash, crlf])
}

fn build_header_block(headers: List(#(String, String))) -> BitArray {
  list.fold(headers, <<>>, fn(acc, entry) {
    let line =
      bit_array.concat([
        bit_array.from_string(entry.0),
        <<": ":utf8>>,
        bit_array.from_string(entry.1),
        <<"\r\n":utf8>>,
      ])
    bit_array.append(acc, line)
  })
}

/// Encode a `Form` and return `#(content_type, body)`.
///
/// `content_type` is the full value to set on the HTTP `Content-Type` header
/// — for example `multipart/form-data; boundary=----abc123`. The boundary is
/// generated freshly per call. Two calls on the same `Form` therefore
/// produce different `content_type` values.
///
/// Note: v0.1.0 uses `gleam/int.random` for boundary character generation.
/// This is sufficient for collision avoidance with normal payloads but is
/// not cryptographically strong; do not rely on the boundary for security
/// invariants.
pub fn encode_form(the_form: Form) -> #(String, BitArray) {
  let boundary = generate_boundary()
  let body = encode(boundary, form.parts(the_form))
  let content_type = "multipart/form-data; boundary=" <> boundary
  #(content_type, body)
}

/// Encode a stream of `StreamPart`s into a yielder of byte chunks.
///
/// Errors propagated from a `StreamPart`'s body iterator are forwarded as
/// `Error(_)`. After the first error, the yielder is exhausted.
pub fn encode_stream(
  boundary: String,
  parts: Yielder(StreamPart),
) -> Yielder(Result(BitArray, MultipartError)) {
  let boundary_bytes = bit_array.from_string(boundary)
  let body =
    yielder.flat_map(parts, fn(the_part) {
      let header_block = build_stream_header_block(the_part)
      let prefix =
        yielder.from_list([
          Ok(<<"--":utf8>>),
          Ok(boundary_bytes),
          Ok(<<"\r\n":utf8>>),
          Ok(header_block),
          Ok(<<"\r\n":utf8>>),
        ])
      let suffix = yielder.from_list([Ok(<<"\r\n":utf8>>)])
      yielder.append(yielder.append(prefix, stream.body(the_part)), suffix)
    })
  let closing =
    yielder.from_list([
      Ok(<<"--":utf8>>),
      Ok(boundary_bytes),
      Ok(<<"--":utf8>>),
      Ok(<<"\r\n":utf8>>),
    ])
  stop_after_first_error(yielder.append(body, closing))
}

fn build_stream_header_block(stream_part: StreamPart) -> BitArray {
  build_header_block(stream.all_headers(stream_part))
}

fn stop_after_first_error(
  source: Yielder(Result(BitArray, MultipartError)),
) -> Yielder(Result(BitArray, MultipartError)) {
  yielder.transform(source, False, fn(seen_error, item) {
    use <- bool.guard(when: seen_error, return: yielder.Done)
    yielder.Next(item, result.is_error(item))
  })
}

const boundary_alphabet_size: Int = 36

fn boundary_char(index: Int) -> String {
  case index {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    15 -> "f"
    16 -> "g"
    17 -> "h"
    18 -> "i"
    19 -> "j"
    20 -> "k"
    21 -> "l"
    22 -> "m"
    23 -> "n"
    24 -> "o"
    25 -> "p"
    26 -> "q"
    27 -> "r"
    28 -> "s"
    29 -> "t"
    30 -> "u"
    31 -> "v"
    32 -> "w"
    33 -> "x"
    34 -> "y"
    _ -> "z"
  }
}

fn generate_boundary() -> String {
  "----multipartkit-" <> random_chars(24, "")
}

fn random_chars(remaining: Int, acc: String) -> String {
  use <- bool.guard(when: remaining <= 0, return: acc)
  let char_index = int.random(boundary_alphabet_size)
  random_chars(remaining - 1, acc <> boundary_char(char_index))
}
