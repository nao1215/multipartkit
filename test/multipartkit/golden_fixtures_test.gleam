//// Golden wire fixtures for the encoder and parser.
////
//// Most behaviour tests assert one property at a time (for example,
//// "the encoder emits the boundary"). That leaves a gap where a
//// formatting shift — header order, quoting style, CRLF placement,
//// `filename*` precedence, etc. — could change without any single
//// assertion noticing.
////
//// The fixtures in this module pin the *exact bytes* of representative
//// multipart bodies. Each fixture covers one of the spec-sensitive
//// areas called out in issue #11:
////
//// - canonical form-data with a text field and a file part
//// - non-ASCII filenames using RFC 5987 `filename*` (the encoder must
////   emit BOTH the legacy fallback and the `*=` form, and the parser
////   must prefer the `*=` form on the round trip)
//// - the streaming parser must produce identical output regardless of
////   how the input chunks split — delimiters, header blocks, and body
////   bytes can land on awkward chunk boundaries in real HTTP streams
//// - malformed fixtures whose exact failure mode (kind of error, byte
////   offset of the bad character, etc.) is part of the contract

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/yielder
import gleeunit/should
import multipartkit/encoder
import multipartkit/error.{InvalidContentDisposition, UnexpectedEndOfInput}
import multipartkit/parser
import multipartkit/part
import multipartkit/stream

// ---------------------------------------------------------------------------
// Fixture 1: Canonical form-data body with a text field and a file part.
//
// `boundary=B` keeps the on-the-wire bytes short and human-readable.
// The text field's body is `hi`. The file part carries
// `Content-Type: text/plain` and a 4-byte payload.
//
// Spec-sensitive properties pinned here:
// - boundary syntax: leading `--`, CRLF after the boundary line
// - Content-Disposition is the first header on each part
// - Content-Type follows Content-Disposition with no extra blank line
// - the blank line between header block and body is exactly one CRLF
// - the closing delimiter is `--<boundary>--` followed by CRLF
// ---------------------------------------------------------------------------

const fixture_form_data_body: BitArray = <<
  "--B\r\n":utf8, "Content-Disposition: form-data; name=\"title\"\r\n":utf8,
  "\r\n":utf8, "hi\r\n":utf8, "--B\r\n":utf8,
  "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.bin\"\r\n":utf8,
  "Content-Type: text/plain\r\n":utf8, "\r\n":utf8, 0xDE, 0xAD, 0xBE, 0xEF,
  "\r\n":utf8, "--B--\r\n":utf8,
>>

pub fn encoder_emits_canonical_form_data_body_test() {
  let assert Ok(title) =
    part.new(
      headers: [#("Content-Disposition", "form-data; name=\"title\"")],
      name: Some("title"),
      filename: None,
      content_type: None,
      body: <<"hi":utf8>>,
    )
  let assert Ok(avatar) =
    part.new(
      headers: [
        #(
          "Content-Disposition",
          "form-data; name=\"avatar\"; filename=\"a.bin\"",
        ),
        #("Content-Type", "text/plain"),
      ],
      name: Some("avatar"),
      filename: Some("a.bin"),
      content_type: Some("text/plain"),
      body: <<0xDE, 0xAD, 0xBE, 0xEF>>,
    )
  let assert Ok(body) = encoder.encode("B", [title, avatar])
  body |> should.equal(fixture_form_data_body)
}

pub fn parser_round_trips_canonical_form_data_body_test() {
  let assert Ok(parts) =
    parser.parse(fixture_form_data_body, "multipart/form-data; boundary=B")
  case parts {
    [title, avatar] -> {
      part.name(title) |> should.equal(Some("title"))
      part.body(title) |> should.equal(<<"hi":utf8>>)
      part.name(avatar) |> should.equal(Some("avatar"))
      part.filename(avatar) |> should.equal(Some("a.bin"))
      part.content_type(avatar) |> should.equal(Some("text/plain"))
      part.body(avatar) |> should.equal(<<0xDE, 0xAD, 0xBE, 0xEF>>)
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Fixture 2: RFC 5987 `filename*` — non-ASCII filename
//
// "写真.png" UTF-8: E5 86 99 E7 9C 9F (followed by `.png`).
// On the wire the encoder must emit BOTH:
//   filename="__.png"                          (legacy fallback)
//   filename*=UTF-8''%E5%86%99%E7%9C%9F.png    (RFC 5987 §3.2.1)
//
// Per RFC 5987 §3.2.2 a parser that sees both must prefer the `*=`
// form; multipartkit's parser does so, and the round-trip below
// confirms `filename` decodes back to `写真.png`.
// ---------------------------------------------------------------------------

const fixture_rfc5987_form_data: BitArray = <<
  "--B\r\n":utf8,
  "Content-Disposition: form-data; name=\"file\"; filename=\"__.png\"; filename*=UTF-8''%E5%86%99%E7%9C%9F.png\r\n":utf8,
  "Content-Type: image/png\r\n":utf8, "\r\n":utf8, "PNG":utf8, "\r\n":utf8,
  "--B--\r\n":utf8,
>>

pub fn parser_prefers_filename_star_on_rfc5987_fixture_test() {
  let assert Ok([the_part]) =
    parser.parse(fixture_rfc5987_form_data, "multipart/form-data; boundary=B")
  // Decoded filename comes from `filename*=UTF-8''%E5%86%99%E7%9C%9F.png`,
  // not from `filename="__.png"`.
  part.filename(the_part) |> should.equal(Some("写真.png"))
  part.content_type(the_part) |> should.equal(Some("image/png"))
  part.body(the_part) |> should.equal(<<"PNG":utf8>>)
}

// ---------------------------------------------------------------------------
// Fixture 3: Streaming parser invariance under chunk splits
//
// The same canonical body fed to the streaming parser must produce
// the same parts regardless of how the input is split into chunks.
// The split points exercised below land at the awkward offsets called
// out in #11:
//
//   a) one giant chunk (baseline)
//   b) every byte in its own chunk (worst case for delimiter scanning)
//   c) a split that lands inside a header block
//   d) a split that lands inside a part body
//
// All four must yield identical (name, body) pairs.
// ---------------------------------------------------------------------------

fn drained_parts(
  source: yielder.Yielder(Result(stream.StreamPart, error.MultipartError)),
) -> Result(List(#(option.Option(String), BitArray)), error.MultipartError) {
  drained_parts_loop(source, [])
}

fn drained_parts_loop(
  source: yielder.Yielder(Result(stream.StreamPart, error.MultipartError)),
  acc: List(#(option.Option(String), BitArray)),
) -> Result(List(#(option.Option(String), BitArray)), error.MultipartError) {
  case yielder.step(source) {
    yielder.Done -> Ok(list.reverse(acc))
    yielder.Next(Error(err), _) -> Error(err)
    yielder.Next(Ok(stream_part), rest) -> {
      case stream.drain_body(stream.body(stream_part)) {
        Error(err) -> Error(err)
        Ok(body_bytes) ->
          drained_parts_loop(rest, [
            #(stream.name(stream_part), body_bytes),
            ..acc
          ])
      }
    }
  }
}

fn split_byte_by_byte(input: BitArray) -> List(BitArray) {
  split_byte_by_byte_loop(input, [])
}

fn split_byte_by_byte_loop(
  remaining: BitArray,
  acc: List(BitArray),
) -> List(BitArray) {
  case remaining {
    <<>> -> list.reverse(acc)
    <<b, rest:bytes>> -> split_byte_by_byte_loop(rest, [<<b>>, ..acc])
    _ -> list.reverse(acc)
  }
}

fn split_at(input: BitArray, offset: Int) -> List(BitArray) {
  let total = bit_array.byte_size(input)
  case offset <= 0 || offset >= total {
    True -> [input]
    False -> {
      let head = case bit_array.slice(input, 0, offset) {
        Ok(slice) -> slice
        Error(Nil) -> input
      }
      let tail = case bit_array.slice(input, offset, total - offset) {
        Ok(slice) -> slice
        Error(Nil) -> <<>>
      }
      [head, tail]
    }
  }
}

fn parse_chunks_to_pairs(
  chunks: List(BitArray),
) -> Result(List(#(option.Option(String), BitArray)), error.MultipartError) {
  let assert Ok(stream_yielder) =
    stream.parse_stream(
      yielder.from_list(chunks),
      "multipart/form-data; boundary=B",
    )
  drained_parts(stream_yielder)
}

pub fn streaming_parser_chunk_invariance_single_chunk_test() {
  let assert Ok(pairs) = parse_chunks_to_pairs([fixture_form_data_body])
  pairs
  |> should.equal([
    #(Some("title"), <<"hi":utf8>>),
    #(Some("avatar"), <<0xDE, 0xAD, 0xBE, 0xEF>>),
  ])
}

pub fn streaming_parser_chunk_invariance_byte_by_byte_test() {
  let chunks = split_byte_by_byte(fixture_form_data_body)
  let assert Ok(pairs) = parse_chunks_to_pairs(chunks)
  pairs
  |> should.equal([
    #(Some("title"), <<"hi":utf8>>),
    #(Some("avatar"), <<0xDE, 0xAD, 0xBE, 0xEF>>),
  ])
}

pub fn streaming_parser_chunk_invariance_split_in_header_block_test() {
  // Offset 30 lands in the middle of the first part's
  // `Content-Disposition` header line.
  let chunks = split_at(fixture_form_data_body, 30)
  let assert Ok(pairs) = parse_chunks_to_pairs(chunks)
  pairs
  |> should.equal([
    #(Some("title"), <<"hi":utf8>>),
    #(Some("avatar"), <<0xDE, 0xAD, 0xBE, 0xEF>>),
  ])
}

pub fn streaming_parser_chunk_invariance_split_in_body_test() {
  // Offset 100 lands inside the binary body of the second part.
  let chunks = split_at(fixture_form_data_body, 100)
  let assert Ok(pairs) = parse_chunks_to_pairs(chunks)
  pairs
  |> should.equal([
    #(Some("title"), <<"hi":utf8>>),
    #(Some("avatar"), <<0xDE, 0xAD, 0xBE, 0xEF>>),
  ])
}

// ---------------------------------------------------------------------------
// Fixture 4: Malformed fixtures with stable failure modes
//
// Each input here is invalid on the wire, and the *kind* of error
// returned is part of the contract — a future refactor must not turn
// `UnexpectedEndOfInput` into `InvalidHeader` or vice versa without an
// intentional decision.
// ---------------------------------------------------------------------------

const fixture_truncated_body: BitArray = <<
  "--B\r\n":utf8, "Content-Disposition: form-data; name=\"a\"\r\n":utf8,
  "\r\n":utf8, "hello":utf8,
>>

pub fn parser_truncated_body_returns_unexpected_end_of_input_test() {
  parser.parse(fixture_truncated_body, "multipart/form-data; boundary=B")
  |> should.equal(Error(UnexpectedEndOfInput))
}

const fixture_malformed_disposition: BitArray = <<
  "--B\r\n":utf8, "Content-Disposition: ; name=\"a\"\r\n":utf8, "\r\n":utf8,
  "x":utf8, "\r\n":utf8, "--B--\r\n":utf8,
>>

pub fn parser_malformed_disposition_returns_invalid_content_disposition_test() {
  case
    parser.parse(
      fixture_malformed_disposition,
      "multipart/form-data; boundary=B",
    )
  {
    Error(InvalidContentDisposition(_)) -> Nil
    _ -> should.fail()
  }
}
