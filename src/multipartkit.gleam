//// Top-level facade for the multipartkit library.
////
//// Re-exports the public types and the most common functions from the
//// submodules. Less frequently used helpers (header lookup, validation,
//// boundary extraction, content-disposition parsing, ...) live on their
//// dedicated submodules.

import gleam/yielder.{type Yielder}
import multipartkit/content_disposition
import multipartkit/encoder
import multipartkit/error
import multipartkit/form
import multipartkit/limit
import multipartkit/parser
import multipartkit/part
import multipartkit/stream

/// Re-export of `multipartkit/part.Part`.
pub type Part =
  part.Part

/// Re-export of `multipartkit/stream.StreamPart`.
pub type StreamPart =
  stream.StreamPart

/// Re-export of `multipartkit/form.Form`.
pub type Form =
  form.Form

/// Re-export of `multipartkit/limit.Limits`.
pub type Limits =
  limit.Limits

/// Re-export of `multipartkit/error.MultipartError`.
pub type MultipartError =
  error.MultipartError

/// Re-export of `multipartkit/content_disposition.ContentDisposition`.
pub type ContentDisposition =
  content_disposition.ContentDisposition

/// Re-export of `multipartkit/parser.parse`.
pub fn parse(
  body: BitArray,
  content_type: String,
) -> Result(List(Part), MultipartError) {
  parser.parse(body, content_type)
}

/// Re-export of `multipartkit/parser.parse_with_limits`.
pub fn parse_with_limits(
  body: BitArray,
  content_type: String,
  limits: Limits,
) -> Result(List(Part), MultipartError) {
  parser.parse_with_limits(body, content_type, limits)
}

/// Re-export of `multipartkit/stream.parse_stream`.
pub fn parse_stream(
  chunks: Yielder(BitArray),
  content_type: String,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  stream.parse_stream(chunks, content_type)
}

/// Re-export of `multipartkit/stream.parse_stream_with_limits`.
pub fn parse_stream_with_limits(
  chunks: Yielder(BitArray),
  content_type: String,
  limits: Limits,
) -> Result(Yielder(Result(StreamPart, MultipartError)), MultipartError) {
  stream.parse_stream_with_limits(chunks, content_type, limits)
}

/// Re-export of `multipartkit/encoder.encode`.
pub fn encode(boundary: String, parts: List(Part)) -> BitArray {
  encoder.encode(boundary, parts)
}

/// Re-export of `multipartkit/encoder.encode_form`.
pub fn encode_form(the_form: Form) -> #(String, BitArray) {
  encoder.encode_form(the_form)
}

/// Re-export of `multipartkit/encoder.encode_stream`.
pub fn encode_stream(
  boundary: String,
  parts: Yielder(StreamPart),
) -> Yielder(Result(BitArray, MultipartError)) {
  encoder.encode_stream(boundary, parts)
}

/// Re-export of `multipartkit/limit.default_limits`.
pub fn default_limits() -> Limits {
  limit.default_limits()
}
