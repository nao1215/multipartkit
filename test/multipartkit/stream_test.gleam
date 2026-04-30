import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/yielder
import gleeunit/should
import multipartkit/error.{
  InvalidContentType, MissingBoundary, PartTooLarge, UnexpectedEndOfInput,
  UnsupportedMediaType,
}
import multipartkit/limit
import multipartkit/stream

const ct = "multipart/form-data; boundary=B"

fn one_part_body() -> BitArray {
  <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n--B--\r\n":utf8,
  >>
}

fn split_into_chunks(buf: BitArray, size: Int) -> yielder.Yielder(BitArray) {
  let total = bit_array.byte_size(buf)
  yielder.unfold(0, fn(offset) {
    case offset >= total {
      True -> yielder.Done
      False -> {
        let take = case offset + size > total {
          True -> total - offset
          False -> size
        }
        case bit_array.slice(buf, offset, take) {
          Ok(chunk) -> yielder.Next(chunk, offset + take)
          Error(_) -> yielder.Done
        }
      }
    }
  })
}

fn drain_parts(
  source: yielder.Yielder(Result(stream.StreamPart, error.MultipartError)),
) -> List(Result(stream.StreamPart, error.MultipartError)) {
  yielder.to_list(source)
}

pub fn parse_stream_outer_invalid_content_type_test() {
  let chunks = yielder.from_list([<<"any":utf8>>])
  stream.parse_stream(chunks, "garbage")
  |> should.equal(Error(InvalidContentType("garbage")))
}

pub fn parse_stream_outer_unsupported_media_type_test() {
  let chunks = yielder.from_list([<<"any":utf8>>])
  stream.parse_stream(chunks, "text/plain; boundary=x")
  |> should.equal(Error(UnsupportedMediaType("text/plain")))
}

pub fn parse_stream_outer_missing_boundary_test() {
  stream.parse_stream(yielder.empty(), "multipart/form-data")
  |> should.equal(Error(MissingBoundary))
}

pub fn parse_stream_yields_parts_test() {
  let chunks = yielder.from_list([one_part_body()])
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  let items = drain_parts(stream_yielder)
  case items {
    [Ok(stream_part)] -> {
      stream.name(stream_part) |> should.equal(Some("a"))
      let assert Ok(body) = stream.drain_body(stream.body(stream_part))
      body |> should.equal(<<"hello":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn parse_stream_handles_chunk_boundaries_test() {
  // Same input split byte-by-byte must produce the same parts.
  let body = one_part_body()
  let chunks = split_into_chunks(body, 1)
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  case drain_parts(stream_yielder) {
    [Ok(stream_part)] -> {
      stream.name(stream_part) |> should.equal(Some("a"))
      let assert Ok(body_bytes) = stream.drain_body(stream.body(stream_part))
      body_bytes |> should.equal(<<"hello":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn parse_stream_first_error_terminates_iterator_test() {
  // Truncated input — parser should yield UnexpectedEndOfInput then Done.
  let truncated = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello":utf8,
  >>
  let chunks = yielder.from_list([truncated])
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  case drain_parts(stream_yielder) {
    [Error(UnexpectedEndOfInput)] -> Nil
    _ -> should.fail()
  }
}

pub fn parse_stream_two_parts_in_input_order_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nyy\r\n--B--\r\n":utf8,
  >>
  let chunks = yielder.from_list([body])
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  case drain_parts(stream_yielder) {
    [Ok(p1), Ok(p2)] -> {
      stream.name(p1) |> should.equal(Some("a"))
      stream.name(p2) |> should.equal(Some("b"))
    }
    _ -> should.fail()
  }
}

pub fn parse_stream_skip_undrained_body_test() {
  let body = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nfirst-body\r\n--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nsecond\r\n--B--\r\n":utf8,
  >>
  let chunks = yielder.from_list([body])
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  // Pull both StreamParts WITHOUT draining their bodies.
  let items =
    yielder.to_list(stream_yielder)
    |> list.filter_map(fn(item) { item })
  case items {
    [first, second] -> {
      stream.name(first) |> should.equal(Some("a"))
      stream.name(second) |> should.equal(Some("b"))
      // Now drain the second body — it should give "second".
      let assert Ok(body_bytes) = stream.drain_body(stream.body(second))
      body_bytes |> should.equal(<<"second":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn parse_stream_pulls_chunks_lazily_test() {
  // Verify that the parser does NOT need to drain the chunks yielder before
  // emitting the first part. We construct a yielder where the second chunk
  // has not yet been pulled when the first part is delivered.
  let chunk_a = <<
    "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n":utf8,
  >>
  let chunk_b = <<
    "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nworld\r\n--B--\r\n":utf8,
  >>
  let chunks = yielder.from_list([chunk_a, chunk_b])
  let assert Ok(stream_yielder) = stream.parse_stream(chunks, ct)
  case yielder.step(stream_yielder) {
    yielder.Next(Ok(first), rest) -> {
      stream.name(first) |> should.equal(Some("a"))
      // The remaining yielder should still produce part `b` after pulling
      // chunk_b on demand.
      case yielder.step(rest) {
        yielder.Next(Ok(second), _) ->
          stream.name(second) |> should.equal(Some("b"))
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn parse_stream_body_too_large_caught_incrementally_test() {
  // Compose an oversized stream whose first chunk alone exceeds
  // max_body_bytes. The error must surface as the very first yielded item;
  // the parser must not have to drain the stream first.
  let chunk_a = <<"--B\r\n":utf8>>
  let chunk_b = <<
    "Content-Disposition: form-data; name=\"a\"\r\n\r\n":utf8,
  >>
  let huge = <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":utf8>>
  let chunks = yielder.from_list([chunk_a, chunk_b, huge])
  let assert Ok(limits) =
    limit.new(
      max_body_bytes: 30,
      max_part_bytes: 1000,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  let assert Ok(stream_yielder) =
    stream.parse_stream_with_limits(chunks, ct, limits)
  case drain_parts(stream_yielder) {
    [Error(error.BodyTooLarge(30))] -> Nil
    _ -> should.fail()
  }
}

pub fn parse_stream_with_limits_propagates_part_too_large_test() {
  let chunks = yielder.from_list([one_part_body()])
  let assert Ok(limits) =
    limit.new(
      max_body_bytes: 1000,
      max_part_bytes: 2,
      max_parts: 100,
      max_header_bytes: 1000,
    )
  let assert Ok(stream_yielder) =
    stream.parse_stream_with_limits(chunks, ct, limits)
  case drain_parts(stream_yielder) {
    [Error(PartTooLarge(2))] -> Nil
    _ -> should.fail()
  }
}

pub fn parse_stream_empty_input_yields_unexpected_eof_test() {
  let assert Ok(stream_yielder) = stream.parse_stream(yielder.empty(), ct)
  case drain_parts(stream_yielder) {
    [Error(UnexpectedEndOfInput)] -> Nil
    _ -> should.fail()
  }
}

pub fn from_datastream_to_datastream_identity_test() {
  let source = yielder.from_list([<<1>>, <<2, 3>>])
  let result =
    source
    |> stream.from_datastream
    |> stream.to_datastream
    |> yielder.to_list
  result |> should.equal([<<1>>, <<2, 3>>])
}
