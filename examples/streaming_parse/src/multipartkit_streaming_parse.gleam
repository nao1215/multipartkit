//// Demonstrate `parse_stream` consuming a `Yielder(BitArray)` lazily.
////
////    cd examples/streaming_parse
////    gleam run
////
//// In v0.1.0 the input chunks yielder is consumed lazily and
//// `max_body_bytes` is enforced incrementally — an oversized stream is
//// rejected at the chunk that pushes it past the limit, before the rest
//// of the input is buffered. Each `StreamPart.body`, however, is
//// materialised as a single buffered chunk before the part is yielded
//// (bounded by `max_part_bytes`). True chunk-by-chunk body streaming is
//// not part of v0.1.0.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/yielder
import multipartkit
import multipartkit/error.{type MultipartError, BodyTooLarge}
import multipartkit/limit
import multipartkit/stream

pub fn main() {
  io.println("# Happy path")
  case run_happy() {
    Ok(_) -> Nil
    Error(_) -> io.println("(unexpected error)")
  }

  io.println("\n# Oversized stream — rejected before all chunks are pulled")
  run_oversized()
}

fn run_happy() -> Result(Nil, MultipartError) {
  let chunks =
    yielder.from_list([
      <<"--B\r\nContent-Disposition: form-data; name=\"hello\"\r\n":utf8>>,
      <<"\r\nworld\r\n":utf8>>,
      <<
        "--B\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"x.png\"\r\nContent-Type: image/png\r\n\r\n":utf8,
      >>,
      <<137, 80, 78, 71>>,
      <<"\r\n--B--\r\n":utf8>>,
    ])

  case multipartkit.parse_stream(chunks, "multipart/form-data; boundary=B") {
    Error(err) -> Error(err)
    Ok(parts_yielder) -> {
      yielder.each(parts_yielder, fn(item) {
        case item {
          Ok(stream_part) -> describe_part(stream_part)
          Error(_) -> io.println("error item — iterator is now exhausted")
        }
      })
      Ok(Nil)
    }
  }
}

fn describe_part(stream_part: stream.StreamPart) -> Nil {
  let label = case stream.name(stream_part) {
    Some(name) -> name
    None -> "(no name)"
  }
  case stream.drain_body(stream.body(stream_part)) {
    Ok(body) -> io.println("- " <> label <> " — " <> describe_body(body))
    Error(_) -> io.println("- " <> label <> " (body errored)")
  }
}

fn describe_body(body: BitArray) -> String {
  case bit_array.to_string(body) {
    Ok(text) -> "text: " <> text
    Error(_) ->
      "binary, " <> int.to_string(bit_array.byte_size(body)) <> " bytes"
  }
}

fn run_oversized() -> Nil {
  let big_first_chunk = <<
    "--B\r\nContent-Disposition: form-data; name=\"big\"\r\n\r\nAAAAAAAAAAAAAAAAAAAA":utf8,
  >>
  let chunks = yielder.from_list([big_first_chunk, <<"\r\n--B--\r\n":utf8>>])
  let assert Ok(limits) =
    limit.new(
      max_body_bytes: 30,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  let assert Ok(parts_yielder) =
    multipartkit.parse_stream_with_limits(
      chunks,
      "multipart/form-data; boundary=B",
      limits,
    )
  case yielder.step(parts_yielder) {
    yielder.Next(Error(BodyTooLarge(limit_value)), _) ->
      io.println(
        "rejected after pulling chunk 1: BodyTooLarge("
        <> int.to_string(limit_value)
        <> ")",
      )
    _ -> io.println("(unexpected outcome)")
  }
}
