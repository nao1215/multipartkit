//// Differential tests: the buffered parser (`multipartkit.parse`) and the
//// streaming parser (`multipartkit/stream.parse`) implement the same
//// grammar with different code. For any input, however it is cut into
//// chunks, both must accept the same messages, return the same parts and
//// reject the same malformed or oversized input.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import metamon
import metamon/generator.{type Generator}
import multipartkit.{type MultipartError}
import multipartkit/stream
import support

type Entry {
  Field(name: String, value: String)
  File(name: String, filename: String, content_type: String, body: BitArray)
}

/// Bytes that are hard for a boundary scanner: CR, LF, dashes and the
/// start of a delimiter line, mixed with arbitrary bytes.
fn tricky_bytes() -> Generator(BitArray) {
  generator.list_of(
    generator.frequency([
      #(4, generator.bit_array(bytes: generator.range(from: 0, to: 12))),
      #(1, generator.return(<<"\r\n":utf8>>)),
      #(1, generator.return(<<"\r\n--":utf8>>)),
      #(1, generator.return(<<"--":utf8>>)),
      #(1, generator.return(<<"\r":utf8>>)),
      #(1, generator.return(<<"\n":utf8>>)),
    ]),
    length: generator.range(from: 0, to: 12),
  )
  |> generator.map(bit_array.concat)
}

fn name_gen() -> Generator(String) {
  generator.string(
    of: generator.Alphanumeric,
    length: generator.range(from: 1, to: 8),
  )
}

fn entry_gen() -> Generator(Entry) {
  generator.one_of([
    generator.tuple2(
      name_gen(),
      generator.string(
        of: generator.PrintableAscii,
        length: generator.range(from: 0, to: 24),
      ),
    )
      |> generator.map(fn(p) { Field(p.0, p.1) }),
    generator.tuple3(
      name_gen(),
      name_gen(),
      generator.tuple2(
        generator.element_of([
          "application/octet-stream", "text/plain", "image/png",
        ]),
        tricky_bytes(),
      ),
    )
      |> generator.map(fn(t) {
        let #(name, filename, #(ct, body)) = t
        File(name, filename <> ".bin", ct, body)
      }),
  ])
}

fn build(entries: List(Entry)) -> #(String, BitArray) {
  entries
  |> list.fold([], fn(acc, entry) {
    case entry {
      Field(name, value) -> support.add_field(acc, name, value)
      File(name, filename, ct, body) ->
        support.add_file(acc, name, filename, ct, body)
    }
  })
  |> multipartkit.encode_form
}

/// Cut `body` into chunks whose sizes cycle through `sizes`.
fn chunk(body: BitArray, sizes: List(Int)) -> List(BitArray) {
  chunk_loop(body, sizes, sizes, [])
}

fn chunk_loop(
  body: BitArray,
  sizes: List(Int),
  all: List(Int),
  acc: List(BitArray),
) -> List(BitArray) {
  let total = bit_array.byte_size(body)
  case total, sizes {
    0, _ -> list.reverse(acc)
    _, [] -> chunk_loop(body, all, all, acc)
    _, [n, ..rest] -> {
      let take = case n > total {
        True -> total
        False -> n
      }
      let assert Ok(head) = bit_array.slice(body, 0, take)
      let assert Ok(tail) = bit_array.slice(body, take, total - take)
      chunk_loop(tail, rest, all, [head, ..acc])
    }
  }
}

type Seen =
  List(#(List(#(String, String)), BitArray))

fn buffered(
  body: BitArray,
  content_type: String,
  limits: multipartkit.Limits,
) -> Result(Seen, MultipartError) {
  case multipartkit.parse(body, content_type, limits) {
    Error(e) -> Error(e)
    Ok(parts) ->
      Ok(
        list.map(parts, fn(p) {
          #(multipartkit.headers(p), multipartkit.body(p))
        }),
      )
  }
}

fn streamed(
  chunks: List(BitArray),
  content_type: String,
  limits: multipartkit.Limits,
) -> Result(Seen, MultipartError) {
  case stream.parse(yielder.from_list(chunks), content_type, limits) {
    Error(e) -> Error(e)
    Ok(parts) -> collect(parts, [])
  }
}

fn collect(
  parts: yielder.Yielder(Result(stream.StreamPart, MultipartError)),
  acc: Seen,
) -> Result(Seen, MultipartError) {
  case yielder.step(parts) {
    yielder.Done -> Ok(list.reverse(acc))
    yielder.Next(Error(e), _) -> Error(e)
    yielder.Next(Ok(sp), rest) ->
      case stream.drain_body(stream.body(sp)) {
        Error(e) -> Error(e)
        Ok(body) -> collect(rest, [#(stream.headers(sp), body), ..acc])
      }
  }
}

fn sizes_gen() -> Generator(List(Int)) {
  generator.list_of(
    generator.int(generator.range(from: 1, to: 40)),
    length: generator.range(from: 1, to: 6),
  )
}

pub fn stream_matches_buffered_for_encoded_forms_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      generator.list_of(entry_gen(), length: generator.range(from: 0, to: 4)),
      sizes_gen(),
    ),
    fn(input) {
      let #(entries, sizes) = input
      let #(content_type, body) = build(entries)
      let limits = multipartkit.default_limits
      let expected = buffered(body, content_type, limits)
      let assert Ok(_) = expected
      assert streamed(chunk(body, sizes), content_type, limits) == expected
    },
  )
}

/// Damage a valid message (drop a byte range, or overwrite one byte) and
/// both parsers must still agree: same parts, or the same error.
pub fn stream_matches_buffered_for_damaged_messages_test() -> Nil {
  metamon.forall(
    generator.tuple3(
      generator.list_of(entry_gen(), length: generator.range(from: 1, to: 3)),
      sizes_gen(),
      generator.tuple3(
        generator.int(generator.range(from: 0, to: 1000)),
        generator.int(generator.range(from: 0, to: 8)),
        generator.int(generator.range(from: 0, to: 255)),
      ),
    ),
    fn(input) {
      let #(entries, sizes, #(at, len, byte)) = input
      let #(content_type, body) = build(entries)
      let total = bit_array.byte_size(body)
      let at = at % total
      let len = case at + len > total {
        True -> total - at
        False -> len
      }
      let assert Ok(head) = bit_array.slice(body, 0, at)
      let assert Ok(tail) = bit_array.slice(body, at + len, total - at - len)
      let damaged = case len {
        0 -> bit_array.concat([head, <<byte>>, tail])
        _ -> bit_array.append(head, tail)
      }
      let limits = multipartkit.default_limits
      assert streamed(chunk(damaged, sizes), content_type, limits)
        == buffered(damaged, content_type, limits)
    },
  )
}

/// Boundary values of every limit: one below, at and one above the size
/// of the message. Limits are inclusive, and both parsers must draw the
/// line at the same byte.
pub fn stream_matches_buffered_at_limit_boundaries_test() -> Nil {
  metamon.forall(
    generator.tuple3(
      generator.list_of(entry_gen(), length: generator.range(from: 1, to: 3)),
      sizes_gen(),
      generator.tuple2(
        generator.element_of(["body", "part", "parts", "header"]),
        generator.int(generator.range(from: -1, to: 1)),
      ),
    ),
    fn(input) {
      let #(entries, sizes, #(which, delta)) = input
      let #(content_type, body) = build(entries)
      let assert Ok(seen) =
        buffered(body, content_type, multipartkit.default_limits)
      let largest_part =
        list.fold(seen, 0, fn(acc, p) {
          let n = bit_array.byte_size(p.1)
          case n > acc {
            True -> n
            False -> acc
          }
        })
      let d = multipartkit.default_limits
      let #(b, p, n, h) = #(
        d.max_body_bytes,
        d.max_part_bytes,
        d.max_parts,
        d.max_header_bytes,
      )
      let at = fn(x) {
        case x + delta < 1 {
          True -> 1
          False -> x + delta
        }
      }
      let limits = case which {
        "body" ->
          Ok(multipartkit.Limits(at(bit_array.byte_size(body)), p, n, h))
        "part" -> Ok(multipartkit.Limits(b, at(largest_part), n, h))
        "parts" -> Ok(multipartkit.Limits(b, p, at(list.length(seen)), h))
        _ -> Ok(multipartkit.Limits(b, p, n, at(header_size(seen))))
      }
      let assert Ok(limits) = limits
      assert streamed(chunk(body, sizes), content_type, limits)
        == buffered(body, content_type, limits)
    },
  )
}

fn header_size(seen: Seen) -> Int {
  list.fold(seen, 0, fn(acc, p) {
    let n =
      list.fold(p.0, 0, fn(a, h) {
        a + bit_array.byte_size(<<h.0:utf8, ": ", h.1:utf8, "\r\n">>)
      })
    case n > acc {
      True -> n
      False -> acc
    }
  })
}

// ---------- raw messages ----------

// Messages written by hand from the pieces of the RFC 2046 §5.1.1 grammar
// that `encode_form` never writes: LF-only lines, transport padding (and
// padding before the closing `--`, which is not a delimiter), preambles,
// epilogues, folded and malformed headers, parts with no headers, and an
// empty body whose blank line is also the delimiter's line break.

fn raw_boundary_gen() -> Generator(String) {
  generator.element_of(["b", "simple boundary", "--x", "a'()+_,-./:=?"])
}

fn line_end_gen() -> Generator(String) {
  generator.element_of(["\r\n", "\n"])
}

fn header_line_gen() -> Generator(String) {
  generator.element_of([
    "Content-Disposition: form-data; name=\"a\"",
    "content-disposition: form-data; name=b; filename=\"f.txt\"",
    "Content-Disposition: form-data;\r\n name=\"folded\"",
    "Content-Disposition: form-data;\n\tname=\"lf-folded\"",
    "Content-Type: text/plain",
    "Content-Disposition: form-data; name=\"a\"; name=\"a\"",
    "X-Space : 1",
    "no colon",
    " leading continuation",
    "X-Cr: a\rb",
  ])
}

fn padding_gen() -> Generator(String) {
  generator.element_of(["", "", " ", "\t ", " --"])
}

fn raw_part_gen() -> Generator(String) {
  generator.tuple4(
    generator.list_of(
      generator.tuple2(header_line_gen(), line_end_gen()),
      length: generator.range(from: 0, to: 3),
    ),
    line_end_gen(),
    generator.element_of(["", "x", "line\r\nline", "-", "--", "\r", "\n"]),
    generator.element_of(["\r\n", "\n", ""]),
  )
  |> generator.map(fn(piece) {
    let #(headers, blank, body, before_delimiter) = piece
    let headers =
      list.map(headers, fn(header) { header.0 <> header.1 }) |> string.concat
    headers <> blank <> body <> before_delimiter
  })
}

fn raw_message_gen() -> Generator(#(String, BitArray)) {
  generator.tuple4(
    raw_boundary_gen(),
    generator.element_of(["", "preamble\r\n", "x\n", "--bx\r\n"]),
    generator.list_of(
      generator.tuple2(padding_gen(), raw_part_gen()),
      length: generator.range(from: 0, to: 3),
    ),
    generator.tuple2(
      padding_gen(),
      generator.element_of(["", "\r\n", "\r\nepilogue", "\n--b\r\n", "x"]),
    ),
  )
  |> generator.map(fn(piece) {
    let #(boundary, preamble, parts, #(close_padding, epilogue)) = piece
    let dash = "--" <> boundary
    let parts =
      list.map(parts, fn(part) { dash <> part.0 <> "\r\n" <> part.1 })
      |> string.concat
    let body = preamble <> parts <> dash <> "--" <> close_padding <> epilogue
    #(
      "multipart/form-data; boundary=\"" <> boundary <> "\"",
      bit_array.from_string(body),
    )
  })
}

pub fn stream_matches_buffered_for_raw_messages_test() -> Nil {
  metamon.forall(generator.tuple2(raw_message_gen(), sizes_gen()), fn(input) {
    let #(#(content_type, body), sizes) = input
    let limits = multipartkit.default_limits
    metamon.classify(
      label: "accepted",
      when: result.is_ok(buffered(body, content_type, limits)),
    )
    assert streamed(chunk(body, sizes), content_type, limits)
      == buffered(body, content_type, limits)
  })
}

/// The same with small limits, so that every limit error is reached on
/// raw input too.
pub fn stream_matches_buffered_for_raw_messages_at_small_limits_test() -> Nil {
  let small = generator.int(generator.range(from: 0, to: 64))
  metamon.forall(
    generator.tuple3(
      raw_message_gen(),
      sizes_gen(),
      generator.tuple4(
        generator.int(generator.range(from: 0, to: 400)),
        small,
        generator.int(generator.range(from: 0, to: 3)),
        small,
      ),
    ),
    fn(input) {
      let #(#(content_type, body), sizes, #(b, p, n, h)) = input
      let limits = multipartkit.Limits(b, p, n, h)
      assert streamed(chunk(body, sizes), content_type, limits)
        == buffered(body, content_type, limits)
    },
  )
}

/// Chunking is not observable: two different splits of the same input
/// give the same result.
pub fn stream_result_does_not_depend_on_the_split_test() -> Nil {
  metamon.forall(
    generator.tuple3(raw_message_gen(), sizes_gen(), sizes_gen()),
    fn(input) {
      let #(#(content_type, body), first, second) = input
      let limits = multipartkit.default_limits
      assert streamed(chunk(body, first), content_type, limits)
        == streamed(chunk(body, second), content_type, limits)
    },
  )
}
