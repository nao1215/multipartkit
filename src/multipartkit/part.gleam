import gleam/list
import gleam/option.{type Option, None, Some}
import multipartkit/internal/text

/// A parsed multipart part.
///
/// `headers` keeps entries in the order they appeared on the wire; header
/// names retain their original casing. Header values have surrounding
/// optional whitespace stripped per RFC 7230 §3.2.4 but are otherwise
/// preserved (no quote unescaping, no parameter normalisation, no inner
/// whitespace collapse).
///
/// `body` is always raw bytes; the parser does not transcode or
/// UTF-8-validate it.
///
/// `name`, `filename`, and `content_type` are convenience caches derived from
/// `Content-Disposition` and `Content-Type` headers per the field/file
/// detection rules. They are not re-derived automatically when a caller
/// constructs a `Part` manually.
pub type Part {
  Part(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: BitArray,
  )
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
/// in the order they appear in `part.headers`.
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
