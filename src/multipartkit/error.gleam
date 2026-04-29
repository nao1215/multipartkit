/// Errors that can be produced by parsing, encoding, or querying a multipart
/// message.
///
/// Variants that carry a payload preserve the offending raw text so callers can
/// surface diagnostics without re-running the parser.
pub type MultipartError {
  /// The Content-Type header had no `boundary` parameter.
  MissingBoundary
  /// The Content-Type header value could not be parsed as a media type.
  InvalidContentType(String)
  /// The boundary value violates the RFC 2046 grammar.
  InvalidBoundary(String)
  /// A header line could not be parsed (missing `:` separator or otherwise
  /// malformed).
  InvalidHeader(String)
  /// A `Content-Disposition` value could not be parsed.
  InvalidContentDisposition(String)
  /// Input ended before a complete message could be parsed.
  UnexpectedEndOfInput
  /// The total bytes consumed from input exceeded `max_body_bytes`.
  BodyTooLarge(limit: Int)
  /// A single part body exceeded `max_part_bytes`.
  PartTooLarge(limit: Int)
  /// The number of parts produced exceeded `max_parts`.
  TooManyParts(limit: Int)
  /// A single part header block exceeded `max_header_bytes`.
  HeaderTooLarge(limit: Int)
  /// A query helper tried to decode a field body as UTF-8 and failed.
  InvalidUtf8Field(name: String)
  /// A required field (text part) was not present.
  MissingField(name: String)
  /// A required file part was not present.
  MissingFile(name: String)
  /// The Content-Type media type is not `multipart/*`.
  UnsupportedMediaType(String)
  /// A syntactically valid feature is intentionally unsupported by this
  /// release.
  UnsupportedFeature(String)
  /// Validation rejected a part because its `Content-Type` is outside an
  /// application-supplied allow-list.
  DisallowedContentType(String)
}
