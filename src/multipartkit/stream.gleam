import gleam/bit_array
import gleam/option.{type Option}
import gleam/yielder.{type Yielder}
import multipartkit/error.{
  type MultipartError, BodyTooLarge, HeaderTooLarge, PartTooLarge, TooManyParts,
  UnexpectedEndOfInput,
}
import multipartkit/header
import multipartkit/internal/bytes
import multipartkit/internal/headers as internal_headers
import multipartkit/internal/scan
import multipartkit/limit.{type Limits}
import multipartkit/part.{type Part}

/// One streamed multipart part.
///
/// Opaque — inspect through `all_headers/1`, `name/1`, `filename/1`,
/// `content_type/1`, and `body/1`. The internal layout may evolve as
/// the streaming surface stabilises (see issue #7 for the chunked-body
/// follow-up) without breaking external callers.
///
/// Body semantics:
///
/// - `body/1` returns a single-pass yielder; once consumed it cannot be
///   replayed. Errors that arise while reading the body
///   (`PartTooLarge`, `UnexpectedEndOfInput`, etc.) are surfaced inline
///   as `Error(_)` items rather than swallowed.
/// - In the current release each `StreamPart` body is materialised as a
///   single buffered chunk before the part is yielded. The body yielder
///   therefore always emits at most one `Ok(BitArray)` (or one
///   `Error(_)`). Per-part memory is bounded by `max_part_bytes`. True
///   chunk-by-chunk body streaming is on the roadmap.
///
/// Note: the public spec describes `body` as `iterator.Iterator(_)`.
/// The current implementation uses `gleam/yielder.Yielder(_)` because
/// gleam_stdlib 1.0.0 dropped the `iterator` module.
pub opaque type StreamPart {
  StreamPart(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: Yielder(Result(BitArray, MultipartError)),
  )
}

/// All headers as `(name, value)` pairs in input order.
pub fn all_headers(stream_part: StreamPart) -> List(#(String, String)) {
  stream_part.headers
}

/// The convenience `name` field derived from `Content-Disposition` for
/// `form-data` parts, or `None`.
pub fn name(stream_part: StreamPart) -> Option(String) {
  stream_part.name
}

/// The convenience `filename` field derived from `Content-Disposition`
/// for `form-data` parts, or `None`.
pub fn filename(stream_part: StreamPart) -> Option(String) {
  stream_part.filename
}

/// The `Content-Type` header value, or `None`.
pub fn content_type(stream_part: StreamPart) -> Option(String) {
  stream_part.content_type
}

/// The single-pass body yielder. See the type-level doc for streaming
/// semantics.
pub fn body(
  stream_part: StreamPart,
) -> Yielder(Result(BitArray, MultipartError)) {
  stream_part.body
}

/// Parse a stream of input chunks using `default_limits()`.
///
/// The outer `Result` reports errors decidable from `content_type` alone.
/// Each yielded item is a `Result` because once body consumption begins,
/// failures can arise later from message structure, limits, or truncation.
/// After the first `Error(_)` is yielded the iterator is exhausted.
pub fn parse_stream(
  chunks: Yielder(BitArray),
  content_type: String,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  parse_stream_with_limits(chunks, content_type, limit.default_limits())
}

/// Parse a stream of input chunks with caller-supplied limits.
///
/// Chunks are pulled lazily: bytes are consumed from `chunks` only as needed
/// to deliver the next part's headers and body. `max_body_bytes` is enforced
/// incrementally as chunks arrive, so an oversized stream is rejected before
/// it is fully buffered. Per-part memory is bounded by `max_part_bytes`.
pub fn parse_stream_with_limits(
  chunks: Yielder(BitArray),
  content_type: String,
  limits: Limits,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  case header.boundary(content_type) {
    Error(err) -> Error(err)
    Ok(boundary_value) -> {
      let pattern = scan.dash_pattern(boundary_value)
      let initial =
        StreamState(
          buf: <<>>,
          cursor: 0,
          chunks: chunks,
          exhausted: False,
          bytes_pulled: 0,
          pattern: pattern,
          limits: limits,
          parts_count: 0,
          started: False,
          done: False,
        )
      Ok(yielder.unfold(initial, step))
    }
  }
}

/// Adapter that returns the source unchanged. Exists so callers can write
/// `source |> from_datastream` in a pipeline.
pub fn from_datastream(source: Yielder(BitArray)) -> Yielder(BitArray) {
  source
}

/// Adapter that returns the source unchanged. Mirror of `from_datastream`.
pub fn to_datastream(source: Yielder(BitArray)) -> Yielder(BitArray) {
  source
}

type StreamState {
  StreamState(
    buf: BitArray,
    cursor: Int,
    chunks: Yielder(BitArray),
    exhausted: Bool,
    bytes_pulled: Int,
    pattern: BitArray,
    limits: Limits,
    parts_count: Int,
    started: Bool,
    done: Bool,
  )
}

type PullOutcome {
  Pulled(state: StreamState)
  Exhausted
  OverBody
}

type PartOutcome {
  PartReady(stream_part: StreamPart, state: StreamState)
  NeedMore
  Failed(error: MultipartError)
}

fn step(
  state: StreamState,
) -> yielder.Step(Result(StreamPart, MultipartError), StreamState) {
  case state.done {
    True -> yielder.Done
    False ->
      case state.started {
        False -> step_find_first(state)
        True -> step_produce_next(state)
      }
  }
}

fn step_find_first(
  state: StreamState,
) -> yielder.Step(Result(StreamPart, MultipartError), StreamState) {
  case scan.find_delimiter(state.buf, state.pattern, 0) {
    scan.Found(_body_end, scan.Closing, _after) -> yielder.Done
    scan.Found(_body_end, scan.Delimiter, after_first) ->
      step_produce_next(
        StreamState(..state, started: True, cursor: after_first),
      )
    scan.Incomplete ->
      case pull_chunk(state) {
        Pulled(next) -> step_find_first(next)
        Exhausted -> halt_with(state, UnexpectedEndOfInput)
        OverBody ->
          halt_with(state, BodyTooLarge(limit.max_body_bytes(state.limits)))
      }
  }
}

fn step_produce_next(
  state: StreamState,
) -> yielder.Step(Result(StreamPart, MultipartError), StreamState) {
  case parse_one_part(state) {
    PartReady(stream_part, next) -> yielder.Next(Ok(stream_part), next)
    Failed(err) -> halt_with(state, err)
    NeedMore ->
      case pull_chunk(state) {
        Pulled(next) -> step_produce_next(next)
        Exhausted -> halt_with(state, UnexpectedEndOfInput)
        OverBody ->
          halt_with(state, BodyTooLarge(limit.max_body_bytes(state.limits)))
      }
  }
}

fn halt_with(
  state: StreamState,
  err: MultipartError,
) -> yielder.Step(Result(StreamPart, MultipartError), StreamState) {
  yielder.Next(Error(err), StreamState(..state, done: True))
}

fn pull_chunk(state: StreamState) -> PullOutcome {
  case state.exhausted {
    True -> Exhausted
    False ->
      case yielder.step(state.chunks) {
        yielder.Done -> Exhausted
        yielder.Next(chunk, rest) -> {
          let size = bit_array.byte_size(chunk)
          let new_pulled = state.bytes_pulled + size
          case new_pulled > limit.max_body_bytes(state.limits) {
            True -> OverBody
            False ->
              Pulled(
                StreamState(
                  ..state,
                  buf: bit_array.append(state.buf, chunk),
                  bytes_pulled: new_pulled,
                  chunks: rest,
                ),
              )
          }
        }
      }
  }
}

fn parse_one_part(state: StreamState) -> PartOutcome {
  case bytes.find_blank_line(state.buf, state.cursor) {
    Error(Nil) -> NeedMore
    Ok(#(blank_at, body_start)) -> finalise_headers(state, blank_at, body_start)
  }
}

fn finalise_headers(
  state: StreamState,
  blank_at: Int,
  body_start: Int,
) -> PartOutcome {
  let header_block_size = body_start - state.cursor
  case header_block_size > limit.max_header_bytes(state.limits) {
    True -> Failed(HeaderTooLarge(limit.max_header_bytes(state.limits)))
    False -> {
      let header_block =
        bytes.slice_or_empty(state.buf, state.cursor, blank_at - state.cursor)
      case internal_headers.parse_block(header_block) {
        Error(err) -> Failed(err)
        Ok(header_list) ->
          case internal_headers.derive_meta(header_list) {
            Error(err) -> Failed(err)
            Ok(meta) -> finalise_body(state, body_start, header_list, meta)
          }
      }
    }
  }
}

fn finalise_body(
  state: StreamState,
  body_start: Int,
  header_list: List(#(String, String)),
  meta: internal_headers.DerivedMeta,
) -> PartOutcome {
  case scan.find_delimiter(state.buf, state.pattern, body_start) {
    scan.Incomplete -> NeedMore
    scan.Found(body_end_excl, kind, after_delim) ->
      finalise_part(
        state,
        body_start,
        body_end_excl,
        kind,
        after_delim,
        header_list,
        meta,
      )
  }
}

fn finalise_part(
  state: StreamState,
  body_start: Int,
  body_end_excl: Int,
  kind: scan.DelimKind,
  after_delim: Int,
  header_list: List(#(String, String)),
  meta: internal_headers.DerivedMeta,
) -> PartOutcome {
  let body_size = body_end_excl - body_start
  case body_size > limit.max_part_bytes(state.limits) {
    True -> Failed(PartTooLarge(limit.max_part_bytes(state.limits)))
    False -> {
      let new_count = state.parts_count + 1
      case new_count > limit.max_parts(state.limits) {
        True -> Failed(TooManyParts(limit.max_parts(state.limits)))
        False -> {
          let part_body = bytes.slice_or_empty(state.buf, body_start, body_size)
          let stream_part =
            StreamPart(
              headers: header_list,
              name: meta.name,
              filename: meta.filename,
              content_type: meta.content_type,
              body: yielder.from_list([Ok(part_body)]),
            )
          let next_done = case kind {
            scan.Closing -> True
            scan.Delimiter -> False
          }
          PartReady(
            stream_part,
            compact_buffer(
              StreamState(
                ..state,
                cursor: after_delim,
                parts_count: new_count,
                done: next_done,
              ),
            ),
          )
        }
      }
    }
  }
}

/// Internal: drop already-consumed bytes from the front of `buf` so memory
/// is bounded by the current part rather than the entire input.
fn compact_buffer(state: StreamState) -> StreamState {
  case state.cursor {
    0 -> state
    _ -> {
      let remaining = bytes.drop(state.buf, state.cursor)
      StreamState(..state, buf: remaining, cursor: 0)
    }
  }
}

/// Build a `StreamPart` from a fully buffered `Part`.
///
/// Useful when feeding parts into `encode_stream` or when adapting a
/// buffered parse result into the streaming API surface.
pub fn from_part(the_part: Part) -> StreamPart {
  StreamPart(
    headers: part.all_headers(the_part),
    name: part.name(the_part),
    filename: part.filename(the_part),
    content_type: part.content_type(the_part),
    body: yielder.from_list([Ok(part.body(the_part))]),
  )
}

/// Consume a `StreamPart`'s body yielder and return the concatenated bytes.
///
/// Stops at the first `Error(_)` and returns it. Because `StreamPart.body`
/// in v0.1.0 always emits a single buffered chunk, this is a constant-time
/// pull over a one-element yielder; future releases that switch to true
/// chunked body streaming will still let this helper drain the whole body.
pub fn drain_body(
  source: Yielder(Result(BitArray, MultipartError)),
) -> Result(BitArray, MultipartError) {
  drain_loop(source, <<>>)
}

fn drain_loop(
  source: Yielder(Result(BitArray, MultipartError)),
  acc: BitArray,
) -> Result(BitArray, MultipartError) {
  case yielder.step(source) {
    yielder.Done -> Ok(acc)
    yielder.Next(Ok(chunk), rest) ->
      drain_loop(rest, bit_array.append(acc, chunk))
    yielder.Next(Error(err), _) -> Error(err)
  }
}
