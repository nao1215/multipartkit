//// Differential tests: the buffered parser (`multipartkit.parse`) and the
//// streaming parser (`multipartkit.parse_stream`) implement the same
//// grammar with different code. For any input, however it is cut into
//// chunks, both must accept the same messages, return the same parts and
//// reject the same malformed or oversized input.

import gleam/bit_array
import gleam/list
import gleam/yielder
import metamon
import metamon/generator.{type Generator}
import metamon/generator/range
import multipartkit
import multipartkit/error.{type MultipartError}
import multipartkit/form
import multipartkit/limit
import multipartkit/part
import multipartkit/stream

type Entry {
  Field(name: String, value: String)
  File(name: String, filename: String, content_type: String, body: BitArray)
}

/// Bytes that are hard for a boundary scanner: CR, LF, dashes and the
/// start of a delimiter line, mixed with arbitrary bytes.
fn tricky_bytes() -> Generator(BitArray) {
  generator.list_of(
    generator.frequency([
      #(4, generator.bit_array(range.constant(0, 12))),
      #(1, generator.return(<<"\r\n":utf8>>)),
      #(1, generator.return(<<"\r\n--":utf8>>)),
      #(1, generator.return(<<"--":utf8>>)),
      #(1, generator.return(<<"\r":utf8>>)),
      #(1, generator.return(<<"\n":utf8>>)),
    ]),
    range.constant(0, 12),
  )
  |> generator.map(bit_array.concat)
}

fn name_gen() -> Generator(String) {
  generator.string_alphanumeric(range.constant(1, 8))
  |> generator.no_edges
}

fn entry_gen() -> Generator(Entry) {
  generator.one_of([
    generator.tuple2(
      name_gen(),
      generator.string_printable_ascii(range.constant(0, 24)),
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
  |> list.fold(form.new(), fn(acc, entry) {
    case entry {
      Field(name, value) -> form.add_field(acc, name, value)
      File(name, filename, ct, body) ->
        form.add_file(acc, name, filename, ct, body)
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
  limits: limit.Limits,
) -> Result(Seen, MultipartError) {
  case multipartkit.parse_with_limits(body, content_type, limits) {
    Error(e) -> Error(e)
    Ok(parts) ->
      Ok(list.map(parts, fn(p) { #(part.all_headers(p), part.body(p)) }))
  }
}

fn streamed(
  chunks: List(BitArray),
  content_type: String,
  limits: limit.Limits,
) -> Result(Seen, MultipartError) {
  case
    multipartkit.parse_stream_with_limits(
      yielder.from_list(chunks),
      content_type,
      limits,
    )
  {
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
        Ok(body) -> collect(rest, [#(stream.all_headers(sp), body), ..acc])
      }
  }
}

fn sizes_gen() -> Generator(List(Int)) {
  generator.list_of(generator.int(range.constant(1, 40)), range.constant(1, 6))
}

pub fn stream_matches_buffered_for_encoded_forms_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      generator.list_of(entry_gen(), range.constant(0, 4)),
      sizes_gen(),
    ),
    fn(input) {
      let #(entries, sizes) = input
      let #(content_type, body) = build(entries)
      let limits = limit.default_limits()
      let expected = buffered(body, content_type, limits)
      let assert Ok(_) = expected
      streamed(chunk(body, sizes), content_type, limits) == expected
    },
  )
}

/// Damage a valid message (drop a byte range, or overwrite one byte) and
/// both parsers must still agree: same parts, or the same error.
pub fn stream_matches_buffered_for_damaged_messages_test() -> Nil {
  metamon.forall(
    generator.tuple3(
      generator.list_of(entry_gen(), range.constant(1, 3)),
      sizes_gen(),
      generator.tuple3(
        generator.int(range.constant(0, 1000)),
        generator.int(range.constant(0, 8)),
        generator.byte(),
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
      let limits = limit.default_limits()
      streamed(chunk(damaged, sizes), content_type, limits)
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
      generator.list_of(entry_gen(), range.constant(1, 3)),
      sizes_gen(),
      generator.tuple2(
        generator.element_of(["body", "part", "parts", "header"]),
        generator.int(range.constant(-1, 1)),
      ),
    ),
    fn(input) {
      let #(entries, sizes, #(which, delta)) = input
      let #(content_type, body) = build(entries)
      let assert Ok(seen) = buffered(body, content_type, limit.default_limits())
      let largest_part =
        list.fold(seen, 0, fn(acc, p) {
          let n = bit_array.byte_size(p.1)
          case n > acc {
            True -> n
            False -> acc
          }
        })
      let d = limit.default_limits()
      let #(b, p, n, h) = #(
        limit.max_body_bytes(d),
        limit.max_part_bytes(d),
        limit.max_parts(d),
        limit.max_header_bytes(d),
      )
      let at = fn(x) {
        case x + delta < 1 {
          True -> 1
          False -> x + delta
        }
      }
      let limits = case which {
        "body" -> limit.new(at(bit_array.byte_size(body)), p, n, h)
        "part" -> limit.new(b, at(largest_part), n, h)
        "parts" -> limit.new(b, p, at(list.length(seen)), h)
        _ -> limit.new(b, p, n, at(header_size(seen)))
      }
      let assert Ok(limits) = limits
      streamed(chunk(body, sizes), content_type, limits)
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
