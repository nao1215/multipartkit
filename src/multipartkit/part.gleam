import gleam/list
import gleam/option.{type Option, None, Some}
import multipartkit/internal/text

/// A parsed multipart part.
///
/// Opaque — construct with `new/5` (or receive from `parser.parse`) and
/// inspect through `headers/1`, `name/1`, `filename/1`, `content_type/1`,
/// and `body/1`. The internal layout may evolve to cache more derived
/// fields without breaking external callers.
///
/// Header semantics on the headers list:
///
/// - Entries are kept in the order they appeared on the wire.
/// - Header names retain their original casing.
/// - Header values have surrounding optional whitespace stripped per
///   RFC 7230 §3.2.4 but are otherwise preserved (no quote unescaping,
///   no parameter normalisation, no inner whitespace collapse).
///
/// Header bytes must be valid UTF-8 — header blocks that contain non-UTF-8
/// bytes are rejected with `InvalidHeader`. The body has no such
/// restriction: it is always treated as raw bytes; the parser does not
/// transcode or UTF-8-validate it.
///
/// `name`, `filename`, and `content_type` are convenience caches derived from
/// `Content-Disposition` and `Content-Type` headers per the field/file
/// detection rules. They are not re-derived automatically when a caller
/// constructs a `Part` manually with `new/5`.
pub opaque type Part {
  Part(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: BitArray,
  )
}

/// Construct a `Part`. The `name`, `filename`, and `content_type` fields
/// are not re-derived from the `headers` list — pass the values you
/// expect callers to see, or use `parser.parse` for automatic
/// derivation.
pub fn new(
  headers headers: List(#(String, String)),
  name name: Option(String),
  filename filename: Option(String),
  content_type content_type: Option(String),
  body body: BitArray,
) -> Part {
  Part(
    headers: headers,
    name: name,
    filename: filename,
    content_type: content_type,
    body: body,
  )
}

/// All headers as `(name, value)` pairs in input order.
pub fn all_headers(part: Part) -> List(#(String, String)) {
  part.headers
}

/// The convenience `name` field derived from `Content-Disposition` for
/// `form-data` parts, or `None` for non-form parts and parts without a
/// disposition header.
pub fn name(part: Part) -> Option(String) {
  part.name
}

/// The convenience `filename` field derived from `Content-Disposition`
/// for `form-data` parts, or `None`.
pub fn filename(part: Part) -> Option(String) {
  part.filename
}

/// The `Content-Type` header value, or `None` if the part has no
/// `Content-Type` header.
pub fn content_type(part: Part) -> Option(String) {
  part.content_type
}

/// The raw body bytes of the part.
pub fn body(part: Part) -> BitArray {
  part.body
}

/// Return the first header value whose name matches `name` ASCII
/// case-insensitively.
pub fn header(part: Part, name: String) -> Option(String) {
  case find_header(part.headers, name) {
    [first, ..] -> Some(first)
    [] -> None
  }
}

/// Return all header values whose name matches `name` ASCII case-insensitively
/// in the order they appear in the part headers.
pub fn headers(part: Part, name: String) -> List(String) {
  find_header(part.headers, name)
}

fn find_header(headers: List(#(String, String)), name: String) -> List(String) {
  list.filter_map(headers, fn(entry) {
    case text.equals_ci(entry.0, name) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}
