//// Parse a multipart body that arrives as a `Yielder(BitArray)` of chunks.
////
////    cd examples/streaming_parse
////    gleam run
////
//// `stream.parse` pulls chunks only when it needs them, so a body over
//// `max_body_bytes` fails at the chunk that crosses the limit. Each part
//// body comes out in chunks of up to 64 KiB.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/yielder
import multipartkit.{type MultipartError, BodyTooLarge}
import multipartkit/stream

pub fn main() {
  io.println("# Happy path")
  case run_happy() {
    Ok(_) -> Nil
    Error(_) -> io.println("(unexpected error)")
  }

  io.println("\n# Oversized stream, rejected before all chunks are pulled")
  run_oversized()

  io.println("\n# Large part, body comes out in several chunks")
  run_chunked_body()
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

  case
    stream.parse(
      chunks,
      "multipart/form-data; boundary=B",
      multipartkit.default_limits,
    )
  {
    Error(err) -> Error(err)
    Ok(parts_yielder) -> {
      yielder.each(parts_yielder, fn(item) {
        case item {
          Ok(stream_part) -> describe_part(stream_part)
          Error(_) -> io.println("error item, the yielder ends here")
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
    Ok(body) -> io.println("- " <> label <> ": " <> describe_body(body))
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
  let limits =
    multipartkit.Limits(..multipartkit.default_limits, max_body_bytes: 30)
  let assert Ok(parts_yielder) =
    stream.parse(chunks, "multipart/form-data; boundary=B", limits)
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

fn run_chunked_body() -> Nil {
  // A 200,000-byte body is larger than one 64 KiB chunk.
  let big_body = repeat_byte(0x41, 200_000)
  let prefix = <<
    "--B\r\nContent-Disposition: form-data; name=\"big\"\r\n\r\n":utf8,
  >>
  let suffix = <<"\r\n--B--\r\n":utf8>>
  let body =
    prefix
    |> bit_array.append(big_body)
    |> bit_array.append(suffix)
  let chunks = yielder.from_list([body])
  let assert Ok(parts_yielder) =
    stream.parse(
      chunks,
      "multipart/form-data; boundary=B",
      multipartkit.default_limits,
    )
  case yielder.step(parts_yielder) {
    yielder.Next(Ok(stream_part), _) -> {
      let body_items = yielder.to_list(stream.body(stream_part))
      io.println(
        "body emitted in "
        <> int.to_string(list_count(body_items))
        <> " chunks ("
        <> int.to_string(total_byte_size(body_items))
        <> " bytes total)",
      )
    }
    _ -> io.println("(unexpected outcome)")
  }
}

fn repeat_byte(byte: Int, count: Int) -> BitArray {
  repeat_byte_loop(byte, count, <<>>)
}

fn repeat_byte_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte_loop(byte, count - 1, bit_array.append(acc, <<byte>>))
  }
}

fn list_count(items: List(a)) -> Int {
  list_count_loop(items, 0)
}

fn list_count_loop(items: List(a), acc: Int) -> Int {
  case items {
    [] -> acc
    [_, ..rest] -> list_count_loop(rest, acc + 1)
  }
}

fn total_byte_size(items: List(Result(BitArray, MultipartError))) -> Int {
  total_byte_size_loop(items, 0)
}

fn total_byte_size_loop(
  items: List(Result(BitArray, MultipartError)),
  acc: Int,
) -> Int {
  case items {
    [] -> acc
    [Ok(chunk), ..rest] ->
      total_byte_size_loop(rest, acc + bit_array.byte_size(chunk))
    [Error(_), ..rest] -> total_byte_size_loop(rest, acc)
  }
}
