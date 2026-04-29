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
/// `body` is single-pass; once consumed it cannot be replayed. Errors that
/// arise while reading the body (`PartTooLarge`, `UnexpectedEndOfInput`,
/// etc.) are surfaced inline as `Error(_)` items rather than swallowed.
///
/// Note: the spec lists `body` as `iterator.Iterator(_)`. v0.1.0 uses
/// `gleam/yielder.Yielder(_)` because gleam_stdlib 1.0.0 dropped the
/// `iterator` module. The streaming surface is experimental and the type
/// may change before v1.0.0.
pub type StreamPart {
  StreamPart(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: Yielder(Result(BitArray, MultipartError)),
  )
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
pub fn parse_stream_with_limits(
  chunks: Yielder(BitArray),
  content_type: String,
  limits: Limits,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  case header.boundary(content_type) {
    Error(err) -> Error(err)
    Ok(boundary_value) -> {
      let pattern = scan.dash_pattern(boundary_value)
      // Read the entire input into memory then reuse the full-body parser.
      // This is correct streaming-shape (outer Result + lazy yielder for the
      // parts) even though the underlying parse is buffered. Spec §"Memory:
      // O(k)" is a target — v0.1.0 keeps the whole buffer to keep the parser
      // simple while still satisfying the public API contract.
      let initial =
        InitialState(
          buf: <<>>,
          pattern: pattern,
          limits: limits,
          cursor: 0,
          parts_count: 0,
          started: False,
          done: False,
          chunks: chunks,
          buffered: False,
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

type InitialState {
  InitialState(
    buf: BitArray,
    pattern: BitArray,
    limits: Limits,
    cursor: Int,
    parts_count: Int,
    started: Bool,
    done: Bool,
    chunks: Yielder(BitArray),
    buffered: Bool,
  )
}

fn ensure_buffered(state: InitialState) -> InitialState {
  case state.buffered {
    True -> state
    False -> {
      let buf = collect_chunks(state.chunks, <<>>)
      InitialState(..state, buf: buf, buffered: True)
    }
  }
}

fn step(
  state: InitialState,
) -> yielder.Step(Result(StreamPart, MultipartError), InitialState) {
  case state.done {
    True -> yielder.Done
    False -> {
      let state = ensure_buffered(state)
      case bit_array.byte_size(state.buf) > state.limits.max_body_bytes {
        True ->
          yielder.Next(
            Error(BodyTooLarge(state.limits.max_body_bytes)),
            InitialState(..state, done: True),
          )
        False ->
          case state.started {
            False ->
              case scan.find_delimiter(state.buf, state.pattern, 0) {
                scan.Incomplete ->
                  yielder.Next(
                    Error(UnexpectedEndOfInput),
                    InitialState(..state, done: True),
                  )
                scan.Found(_body_end, scan.Closing, _after) -> yielder.Done
                scan.Found(_body_end, scan.Delimiter, after_first) ->
                  produce_next(
                    InitialState(..state, started: True, cursor: after_first),
                  )
              }
            True -> produce_next(state)
          }
      }
    }
  }
}

fn produce_next(
  state: InitialState,
) -> yielder.Step(Result(StreamPart, MultipartError), InitialState) {
  case state.cursor > state.limits.max_body_bytes {
    True ->
      yielder.Next(
        Error(BodyTooLarge(state.limits.max_body_bytes)),
        InitialState(..state, done: True),
      )
    False ->
      case bytes.find_blank_line(state.buf, state.cursor) {
        Error(Nil) ->
          yielder.Next(
            Error(UnexpectedEndOfInput),
            InitialState(..state, done: True),
          )
        Ok(#(blank_at, body_start)) -> {
          let header_block_size = body_start - state.cursor
          case header_block_size > state.limits.max_header_bytes {
            True ->
              yielder.Next(
                Error(HeaderTooLarge(state.limits.max_header_bytes)),
                InitialState(..state, done: True),
              )
            False -> {
              let header_block =
                bytes.slice_or_empty(
                  state.buf,
                  state.cursor,
                  blank_at - state.cursor,
                )
              case internal_headers.parse_block(header_block) {
                Error(err) ->
                  yielder.Next(Error(err), InitialState(..state, done: True))
                Ok(header_list) ->
                  case internal_headers.derive_meta(header_list) {
                    Error(err) ->
                      yielder.Next(
                        Error(err),
                        InitialState(..state, done: True),
                      )
                    Ok(meta) ->
                      case
                        scan.find_delimiter(
                          state.buf,
                          state.pattern,
                          body_start,
                        )
                      {
                        scan.Incomplete ->
                          yielder.Next(
                            Error(UnexpectedEndOfInput),
                            InitialState(..state, done: True),
                          )
                        scan.Found(body_end_excl, kind, after_delim) -> {
                          let body_size = body_end_excl - body_start
                          case body_size > state.limits.max_part_bytes {
                            True ->
                              yielder.Next(
                                Error(PartTooLarge(state.limits.max_part_bytes)),
                                InitialState(..state, done: True),
                              )
                            False -> {
                              let part_body =
                                bytes.slice_or_empty(
                                  state.buf,
                                  body_start,
                                  body_size,
                                )
                              let new_count = state.parts_count + 1
                              case new_count > state.limits.max_parts {
                                True ->
                                  yielder.Next(
                                    Error(TooManyParts(state.limits.max_parts)),
                                    InitialState(..state, done: True),
                                  )
                                False -> {
                                  let stream_part =
                                    StreamPart(
                                      headers: header_list,
                                      name: meta.name,
                                      filename: meta.filename,
                                      content_type: meta.content_type,
                                      body: yielder.from_list([Ok(part_body)]),
                                    )
                                  let next_state = case kind {
                                    scan.Closing ->
                                      InitialState(
                                        ..state,
                                        cursor: after_delim,
                                        parts_count: new_count,
                                        done: True,
                                      )
                                    scan.Delimiter ->
                                      InitialState(
                                        ..state,
                                        cursor: after_delim,
                                        parts_count: new_count,
                                      )
                                  }
                                  yielder.Next(Ok(stream_part), next_state)
                                }
                              }
                            }
                          }
                        }
                      }
                  }
              }
            }
          }
        }
      }
  }
}

fn collect_chunks(chunks: Yielder(BitArray), acc: BitArray) -> BitArray {
  case yielder.step(chunks) {
    yielder.Done -> acc
    yielder.Next(chunk, rest) ->
      collect_chunks(rest, bit_array.append(acc, chunk))
  }
}

/// Internal: create a stream-part record from a fully buffered part. Used by
/// tests and for converting buffered parses to stream output.
pub fn from_part(the_part: Part) -> StreamPart {
  StreamPart(
    headers: the_part.headers,
    name: the_part.name,
    filename: the_part.filename,
    content_type: the_part.content_type,
    body: yielder.from_list([Ok(the_part.body)]),
  )
}

/// Internal: best-effort consumption of a `StreamPart` body into a single
/// `BitArray`. Used for testing.
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
