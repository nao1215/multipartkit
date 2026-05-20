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
  /// `Part.new/5` was given a header whose value contains a `CR` (`\r`),
  /// `LF` (`\n`), or `NUL` byte. Allowing these unchecked would let an
  /// attacker who controls the value smuggle additional header lines
  /// into the encoded wire image — the multipart variant of CRLF
  /// response splitting. The carried name and value are the offending
  /// pair so callers can render diagnostics without re-parsing.
  InvalidHeaderValue(name: String, value: String)
  /// `Part.new/5` was given a header whose name contains a `CR`, `LF`,
  /// `NUL`, or `:`. Header names that include any of these would either
  /// inject a header break or split into a different `name: value` pair
  /// at parse time. Carries the offending name.
  InvalidHeaderName(name: String)
  /// A `Content-Disposition` quoted-string parameter contained a
  /// `\X` escape whose `X` is outside the RFC 7230 §3.2.6
  /// `quoted-pair` grammar (`HTAB / SP / VCHAR / obs-text`). The
  /// offending second character is not `HTAB`, `SP`, a `VCHAR`
  /// (`%x21-7E`), nor `obs-text` (`%x80-FF`) — for example
  /// `NUL`, `CR`, `LF`, or any other ASCII control byte. Allowing
  /// these would let an attacker smuggle `NUL` into the decoded
  /// `name` / `filename` (e.g. for C-string truncation attacks).
  /// The carried value is the original Content-Disposition header
  /// text so callers can render diagnostics.
  InvalidQuotedPair(String)
}
