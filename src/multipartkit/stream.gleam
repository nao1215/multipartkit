//// Parse and encode multipart bodies a chunk at a time, for bodies too large
//// to hold in memory.
////
//// A part's headers are read whole, but its body is handed out as a
//// `Yielder` of chunks of up to 64 KiB.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{type Option, Some}
import gleam/result
import gleam/yielder.{type Yielder}
import multipartkit.{
  type Limits, type MultipartError, type Part, BodyTooLarge, HeaderTooLarge,
  InvalidBoundary, InvalidContentType, InvalidHeader, MissingBoundary,
  PartTooLarge, TooManyParts, UnexpectedEndOfInput, UnsupportedMediaType,
}
import multipartkit/internal/bytes
import multipartkit/internal/headers as header_block
import multipartkit/internal/scan
import multipartkit/internal/text

/// One part of a streamed multipart body.
///
/// Get one from `parse` or `from_part`. The body can be read only once.
pub opaque type StreamPart {
  // The headers come from a parsed or validated `Part`, so `encode` can write
  // them without checking them again.
  StreamPart(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: Yielder(Result(BitArray, MultipartError)),
  )
}

/// Returns every header of the part in the order it was written.
///
pub fn headers(part: StreamPart) -> List(#(String, String)) {
  part.headers
}

/// Returns the `name` parameter of a `form-data` part, as
/// `multipartkit.name` does.
///
pub fn name(part: StreamPart) -> Option(String) {
  part.name
}

/// Returns the filename of a `form-data` part, as `multipartkit.filename`
/// does.
///
pub fn filename(part: StreamPart) -> Option(String) {
  part.filename
}

/// Returns the value of the part's `Content-Type` header.
///
pub fn content_type(part: StreamPart) -> Option(String) {
  part.content_type
}

/// Returns the part's body as chunks of up to 64 KiB. An empty body is one
/// empty chunk.
///
/// The yielder can be run once. A read error, such as `PartTooLarge`, comes
/// out as an `Error` item and ends it.
///
pub fn body(part: StreamPart) -> Yielder(Result(BitArray, MultipartError)) {
  part.body
}

/// Parses a multipart body that arrives as chunks.
///
/// The outer `Result` reports a bad `content_type`, with the same errors as
/// `multipartkit.parse`. Each item is a part or the error that stopped
/// parsing, after which the yielder ends.
///
/// Chunks are pulled only when the next part is needed, and the limits are
/// checked as they arrive, so a body or part that is too large fails at the
/// chunk that crosses the limit. Up to one part is held in memory at a time.
/// The results match `multipartkit.parse` however the input is split.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(parts) =
///   stream.parse(chunks, content_type, multipartkit.default_limits)
/// yielder.each(parts, fn(item) {
///   case item {
///     Ok(part) -> save(stream.name(part), stream.body(part))
///     Error(error) -> log(error)
///   }
/// })
/// ```
///
pub fn parse(
  chunks: Yielder(BitArray),
  content_type: String,
  limits: Limits,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  use boundary <- result.map(read_boundary(content_type))
  let initial =
    State(
      buffer: <<>>,
      cursor: 0,
      chunks:,
      bytes_pulled: 0,
      pattern: scan.dash_pattern(boundary),
      limits:,
      parts_count: 0,
      over_limit: False,
      started: False,
      done: False,
    )
  yielder.unfold(initial, step)
}

// The same errors as `multipartkit.parse`.
fn read_boundary(content_type: String) -> Result(String, MultipartError) {
  text.boundary(content_type)
  |> result.map_error(fn(fault) {
    case fault {
      text.MalformedContentType -> InvalidContentType(content_type)
      text.NotMultipart(media_type) -> UnsupportedMediaType(media_type)
      text.NoBoundary -> MissingBoundary
      text.BadBoundary(boundary) -> InvalidBoundary(boundary)
    }
  })
}

/// Encodes parts with the given boundary as a yielder of byte chunks.
///
/// An invalid boundary gives a single `Error(InvalidBoundary(boundary))`, as
/// `multipartkit.encode` does. A header or body line that starts with `--`
/// and the boundary is found as it is written, and gives
/// `Error(InvalidBoundary(boundary))` after the chunks before it. An error
/// from a part's body is passed on. Either error ends the yielder.
///
pub fn encode(
  parts: Yielder(StreamPart),
  boundary: String,
) -> Yielder(Result(BitArray, MultipartError)) {
  use <- bool.guard(
    when: !text.is_valid_boundary(boundary),
    return: yielder.single(Error(InvalidBoundary(boundary))),
  )
  let delimiter = <<"--":utf8, boundary:utf8, "\r\n":utf8>>
  let pattern = scan.dash_pattern(boundary)
  let collision = Error(InvalidBoundary(boundary))
  parts
  |> yielder.flat_map(fn(part) {
    let headers = header_block.encode_block(part.headers)
    case scan.check_line_starts(Some(<<>>), headers, pattern) {
      Error(Nil) -> yielder.single(collision)
      Ok(_) ->
        yielder.single(Ok(<<delimiter:bits, headers:bits, "\r\n":utf8>>))
        |> yielder.append(check_body(part.body, pattern, collision))
        |> yielder.append(yielder.single(Ok(<<"\r\n":utf8>>)))
    }
  })
  |> yielder.append(
    yielder.single(Ok(<<"--":utf8, boundary:utf8, "--\r\n":utf8>>)),
  )
  |> stop_after_first_error
}

/// Passes the body chunks on, and replaces the first chunk in which a line
/// starts with the dash-boundary by `collision`.
fn check_body(
  body: Yielder(Result(BitArray, MultipartError)),
  pattern: BitArray,
  collision: Result(BitArray, MultipartError),
) -> Yielder(Result(BitArray, MultipartError)) {
  // The body starts a line, after the blank line that ends the headers.
  yielder.transform(body, Some(<<>>), fn(carry, item) {
    case item {
      Error(error) -> yielder.Next(Error(error), carry)
      Ok(chunk) ->
        case scan.check_line_starts(carry, chunk, pattern) {
          Ok(carry) -> yielder.Next(item, carry)
          Error(Nil) -> yielder.Next(collision, carry)
        }
    }
  })
}

fn stop_after_first_error(
  source: Yielder(Result(BitArray, MultipartError)),
) -> Yielder(Result(BitArray, MultipartError)) {
  yielder.transform(source, False, fn(seen_error, item) {
    use <- bool.guard(when: seen_error, return: yielder.Done)
    yielder.Next(item, result.is_error(item))
  })
}

/// Turns a buffered part into a stream part, for example to pass it to
/// `encode`.
///
pub fn from_part(part: Part) -> StreamPart {
  StreamPart(
    headers: multipartkit.headers(part),
    name: multipartkit.name(part),
    filename: multipartkit.filename(part),
    content_type: multipartkit.content_type(part),
    body: chunk_body(multipartkit.body(part)),
  )
}

/// Reads a body yielder to the end and joins the chunks, stopping at the
/// first error.
///
/// ## Examples
///
/// ```gleam
/// stream.drain_body(stream.body(part))
/// // -> Ok(<<"hello">>)
/// ```
///
pub fn drain_body(
  body: Yielder(Result(BitArray, MultipartError)),
) -> Result(BitArray, MultipartError) {
  yielder.try_fold(body, <<>>, fn(joined, chunk) {
    result.map(chunk, bit_array.append(joined, _))
  })
}

// Parser state ----------------------------------------------------------------

/// Largest body chunk handed out by `body`.
const body_chunk_size: Int = 65_536

type State {
  State(
    // Bytes pulled but not yet consumed, and the read position in them.
    buffer: BitArray,
    cursor: Int,
    chunks: Yielder(BitArray),
    bytes_pulled: Int,
    pattern: BitArray,
    limits: Limits,
    parts_count: Int,
    // Whether a byte past max_body_bytes was pulled. The buffer stops at the
    // limit, and needing a byte past it is BodyTooLarge, as in
    // multipartkit.parse.
    over_limit: Bool,
    // Whether the first delimiter has been found, and whether the yielder
    // has finished.
    started: Bool,
    done: Bool,
  )
}

type PullOutcome {
  Pulled(state: State)
  Exhausted
}

type PartOutcome {
  PartReady(part: StreamPart, state: State)
  NeedMore
  Failed(error: MultipartError)
}

fn step(
  state: State,
) -> yielder.Step(Result(StreamPart, MultipartError), State) {
  case state.done, state.started {
    True, _ -> yielder.Done
    False, False -> step_find_first(state)
    False, True -> step_produce_next(state)
  }
}

fn step_find_first(
  state: State,
) -> yielder.Step(Result(StreamPart, MultipartError), State) {
  case scan.find_delimiter(state.buffer, state.pattern, 0) {
    // A body with no parts. The epilogue still counts against
    // max_body_bytes, as in parse_body.
    scan.Found(_, scan.Closing, _) ->
      case drain_epilogue(state) {
        Ok(Nil) -> yielder.Done
        Error(error) -> halt_with(state, error)
      }
    scan.Found(_, scan.Delimiter, after_first) ->
      step_produce_next(State(..state, started: True, cursor: after_first))
    scan.Incomplete(_) -> pull_then(state, step_find_first)
  }
}

fn step_produce_next(
  state: State,
) -> yielder.Step(Result(StreamPart, MultipartError), State) {
  case parse_one_part(state) {
    PartReady(part, next) -> yielder.Next(Ok(part), next)
    Failed(error) -> halt_with(state, error)
    NeedMore -> pull_then(state, step_produce_next)
  }
}

fn pull_then(
  state: State,
  continue: fn(State) -> yielder.Step(Result(StreamPart, MultipartError), State),
) -> yielder.Step(Result(StreamPart, MultipartError), State) {
  use <- bool.guard(
    when: state.over_limit,
    return: halt_with(state, BodyTooLarge(state.limits.max_body_bytes)),
  )
  case pull_chunk(state) {
    Pulled(next) -> continue(next)
    Exhausted -> halt_with(state, UnexpectedEndOfInput)
  }
}

fn halt_with(
  state: State,
  error: MultipartError,
) -> yielder.Step(Result(StreamPart, MultipartError), State) {
  yielder.Next(Error(error), State(..state, done: True))
}

fn pull_chunk(state: State) -> PullOutcome {
  case yielder.step(state.chunks) {
    yielder.Done -> Exhausted
    yielder.Next(chunk, rest) -> {
      let limit = state.limits.max_body_bytes
      let pulled = state.bytes_pulled + bit_array.byte_size(chunk)
      // Keep only the bytes up to the limit, so that a problem before it is
      // still found, whichever chunk the limit falls in.
      let #(chunk, pulled, over_limit) = case pulled > limit {
        True -> #(
          bytes.slice_or_empty(chunk, 0, int.max(limit - state.bytes_pulled, 0)),
          int.max(limit, state.bytes_pulled),
          True,
        )
        False -> #(chunk, pulled, False)
      }
      Pulled(
        State(
          ..state,
          buffer: bit_array.append(state.buffer, chunk),
          bytes_pulled: pulled,
          chunks: rest,
          over_limit:,
        ),
      )
    }
  }
}

fn parse_one_part(state: State) -> PartOutcome {
  case bytes.find_blank_line(state.buffer, state.cursor) {
    // Without a blank line yet, fail once the buffered headers are already
    // over the limit instead of pulling the whole body, as
    // multipartkit.parse does for a header block that never ends.
    Error(Nil) -> {
      let limit = state.limits.max_header_bytes
      case bit_array.byte_size(state.buffer) - state.cursor > limit {
        True -> Failed(HeaderTooLarge(limit))
        False -> NeedMore
      }
    }
    Ok(#(blank_at, body_start)) -> {
      let limit = state.limits.max_header_bytes
      use <- bool.guard(
        when: body_start - state.cursor > limit,
        return: Failed(HeaderTooLarge(limit)),
      )
      let block =
        bytes.slice_or_empty(
          state.buffer,
          state.cursor,
          blank_at - state.cursor,
        )
      case parse_part_headers(block) {
        Error(error) -> Failed(error)
        Ok(head) -> parse_body(state, body_start, head)
      }
    }
  }
}

/// Parses one part's header block into a part with an empty body, as
/// `multipartkit.parse` does. `new_part` reads the name, filename and
/// content type, and accepts every header `parse_block` returns.
fn parse_part_headers(block: BitArray) -> Result(Part, MultipartError) {
  use headers <- result.try(header_block.parse_block(block, InvalidHeader))
  multipartkit.new_part(headers:, body: <<>>)
}

fn parse_body(state: State, body_start: Int, head: Part) -> PartOutcome {
  let limit = state.limits.max_part_bytes
  case scan.find_delimiter(state.buffer, state.pattern, body_start) {
    scan.Found(body_end, kind, after) -> {
      let size = body_end - body_start
      use <- bool.guard(when: size > limit, return: Failed(PartTooLarge(limit)))
      let parts_count = state.parts_count + 1
      use <- bool.guard(
        when: parts_count > state.limits.max_parts,
        return: Failed(TooManyParts(state.limits.max_parts)),
      )
      let part =
        StreamPart(
          ..from_part(head),
          body: chunk_body(bytes.slice_or_empty(state.buffer, body_start, size)),
        )
      let next = State(..state, cursor: after, parts_count:)
      case kind {
        scan.Delimiter -> PartReady(part, compact_buffer(next))
        // The epilogue after the closing delimiter is ignored, but it still
        // counts against max_body_bytes, as in multipartkit.parse, so the
        // result does not depend on how the input was split.
        scan.Closing ->
          case drain_epilogue(next) {
            Error(error) -> Failed(error)
            Ok(Nil) ->
              PartReady(
                part,
                State(..next, buffer: <<>>, cursor: 0, done: True),
              )
          }
      }
    }
    // The bytes before body_until are body whatever comes next, so fail
    // as soon as they are over the limit, without pulling more chunks.
    scan.Incomplete(body_until) ->
      case body_until - body_start > limit {
        True -> Failed(PartTooLarge(limit))
        False -> NeedMore
      }
  }
}

fn drain_epilogue(state: State) -> Result(Nil, MultipartError) {
  let limit = state.limits.max_body_bytes
  use <- bool.guard(when: state.over_limit, return: Error(BodyTooLarge(limit)))
  drain_loop(state.chunks, state.bytes_pulled, limit)
}

fn drain_loop(
  chunks: Yielder(BitArray),
  pulled: Int,
  limit: Int,
) -> Result(Nil, MultipartError) {
  case yielder.step(chunks) {
    yielder.Done -> Ok(Nil)
    yielder.Next(chunk, rest) -> {
      let pulled = pulled + bit_array.byte_size(chunk)
      case pulled > limit {
        True -> Error(BodyTooLarge(limit))
        False -> drain_loop(rest, pulled, limit)
      }
    }
  }
}

/// Drops the consumed bytes from the front of the buffer, so memory is
/// bounded by the current part.
fn compact_buffer(state: State) -> State {
  case state.cursor {
    0 -> state
    cursor ->
      State(..state, buffer: bytes.drop(state.buffer, cursor), cursor: 0)
  }
}

fn chunk_body(body: BitArray) -> Yielder(Result(BitArray, MultipartError)) {
  let total = bit_array.byte_size(body)
  use <- bool.guard(when: total == 0, return: yielder.single(Ok(<<>>)))
  yielder.unfold(0, fn(offset) {
    case offset >= total {
      True -> yielder.Done
      False -> {
        let take = int.min(body_chunk_size, total - offset)
        yielder.Next(
          Ok(bytes.slice_or_empty(body, offset, take)),
          offset + take,
        )
      }
    }
  })
}
