import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import multipartkit/error.{
  type MultipartError, InvalidHeaderName, InvalidHeaderValue,
}
import multipartkit/internal/disposition
import multipartkit/internal/text

/// A parsed multipart part.
///
/// Opaque — construct with `new/5` (or receive from `parser.parse`) and
/// inspect through `all_headers/1`, `name/1`, `filename/1`,
/// `content_type/1`, and `body/1`. The case-insensitive
/// `header(part, name)` and `headers(part, name)` helpers below are the
/// supported way to look up a header value by name. The internal
/// layout may evolve to cache more derived fields without breaking
/// external callers.
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
/// detection rules. When `new/5` is given non-`None` cache values without
/// the corresponding header entry in `headers`, the header is synthesised
/// so the cached value also appears on the wire (see `new/5` for details).
pub opaque type Part {
  Part(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: BitArray,
  )
}

/// Construct a `Part`.
///
/// The `name`, `filename`, and `content_type` parameters double as wire
/// instructions: when one of them is `Some(_)` and the corresponding header
/// is absent from `headers`, the constructor synthesises the missing header
/// (matching the shape `multipartkit/form.add_field` / `add_file` would
/// emit) so the cached value also appears in the encoded wire image and
/// survives a `multipartkit.encode |> multipartkit.parse` round trip.
///
/// Synthesis rules:
///
/// - `name: Some(n)` and no `Content-Disposition` header → prepends
///   `Content-Disposition: form-data; name="n"` (with `; filename=...`
///   appended when `filename` is also `Some(_)`, using the RFC 5987
///   `filename*=` form for non-ASCII filenames).
/// - `content_type: Some(ct)` and no `Content-Type` header → prepends
///   `Content-Type: ct`.
/// - `filename: Some(_)` without `name` does not synthesise a
///   `Content-Disposition` (RFC 7578 §4.2 requires `name`); the value is
///   stored as the cache only.
/// - When the relevant header IS present in `headers`, the constructor
///   leaves the headers list untouched — the caller's explicit header wins.
///
/// Header names and values are validated to prevent CRLF / NUL injection
/// into the encoded wire image. A header value that contains `\r`, `\n`,
/// or NUL would otherwise let an attacker who controls the value smuggle
/// additional header lines into the encoded part — the multipart variant
/// of CRLF response splitting (RFC 9110 §5.5 disallows these bytes in
/// `field-value`). Header names additionally cannot contain `:` (would
/// split the header at parse time). The same CRLF / NUL guard applies to
/// `name`, `filename`, and `content_type` because they may be promoted to
/// header values by the synthesis rules above. The constructor rejects
/// these inputs with `Error(InvalidHeaderName(_))` /
/// `Error(InvalidHeaderValue(_, _))` rather than silently emitting an
/// off-spec wire image.
pub fn new(
  headers headers: List(#(String, String)),
  name name: Option(String),
  filename filename: Option(String),
  content_type content_type: Option(String),
  body body: BitArray,
) -> Result(Part, MultipartError) {
  use normalised <- result.try(validate_and_normalise_headers(headers, []))
  use _ <- result.try(reject_breaking_bytes("Content-Disposition", name))
  use _ <- result.try(reject_breaking_bytes("Content-Disposition", filename))
  use _ <- result.try(reject_breaking_bytes("Content-Type", content_type))
  let synthesised =
    synthesise_missing_headers(normalised, name, filename, content_type)
  Ok(Part(
    headers: synthesised,
    name: name,
    filename: filename,
    content_type: content_type,
    body: body,
  ))
}

/// Internal escape hatch — skips header-injection validation. Used by
/// `multipartkit/form` and the parser, both of which sanitise or
/// already-validated their inputs before constructing the `Part`. NOT
/// part of the public surface; the `@internal` attribute keeps it out
/// of the rendered docs and signals the contract to other tooling.
@internal
pub fn unchecked_new(
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

/// Walk the input header list, rejecting CRLF / NUL injection attempts
/// and stripping RFC 7230 §3.2.4 OWS (space and horizontal tab) from the
/// surrounding edges of each value. The OWS stripping mirrors what the
/// parser does on the wire side, so a `Part` constructed with
/// `[#("X-Foo", " spaced ")]` round-trips equal to itself through
/// `encode → parse`. The returned list preserves the input order so
/// `all_headers` / `headers` keep their documented "wire order" property.
fn validate_and_normalise_headers(
  headers: List(#(String, String)),
  acc: List(#(String, String)),
) -> Result(List(#(String, String)), MultipartError) {
  case headers {
    [] -> Ok(list.reverse(acc))
    [#(name, value), ..rest] -> {
      use <- bool.guard(
        when: !valid_header_name(name),
        return: Error(InvalidHeaderName(name)),
      )
      use <- bool.guard(
        when: !valid_header_value(value),
        return: Error(InvalidHeaderValue(name, value)),
      )
      validate_and_normalise_headers(rest, [#(name, trim_ows(value)), ..acc])
    }
  }
}

/// If `value` is `Some(v)` and `v` contains a CR / LF / NUL byte, surface
/// it as `InvalidHeaderValue(header_name, v)` so the user sees the same
/// error shape they would get for the raw header pair. `header_name` is
/// the wire header that synthesis would derive from this parameter
/// (`Content-Disposition` for `name` / `filename`, `Content-Type` for
/// `content_type`); reusing it makes the error point at the actual
/// failure mode without inventing a new error variant.
fn reject_breaking_bytes(
  header_name: String,
  value: Option(String),
) -> Result(Nil, MultipartError) {
  case value {
    None -> Ok(Nil)
    Some(v) ->
      case disposition.has_header_breaking_bytes(v) {
        True -> Error(InvalidHeaderValue(header_name, v))
        False -> Ok(Nil)
      }
  }
}

/// Prepend `Content-Disposition` (when `name` is `Some(_)` and missing
/// from `existing`) and `Content-Type` (when `content_type` is `Some(_)`
/// and missing from `existing`) to mirror what the wire-side parser would
/// derive from those headers. Header order is `[Content-Disposition,
/// Content-Type, ...existing]`, matching what `multipartkit/form.add_file`
/// emits.
fn synthesise_missing_headers(
  existing: List(#(String, String)),
  name: Option(String),
  filename: Option(String),
  content_type: Option(String),
) -> List(#(String, String)) {
  let with_content_type = case content_type {
    None -> existing
    Some(ct) ->
      case has_header_ci(existing, "content-type") {
        True -> existing
        False -> [#("Content-Type", ct), ..existing]
      }
  }
  case name {
    None -> with_content_type
    Some(n) ->
      case has_header_ci(with_content_type, "content-disposition") {
        True -> with_content_type
        False -> [
          #(
            "Content-Disposition",
            disposition.build_form_data_value(n, filename),
          ),
          ..with_content_type
        ]
      }
  }
}

fn has_header_ci(
  headers: List(#(String, String)),
  lowercase_name: String,
) -> Bool {
  case headers {
    [] -> False
    [#(k, _), ..rest] ->
      case text.equals_ci(k, lowercase_name) {
        True -> True
        False -> has_header_ci(rest, lowercase_name)
      }
  }
}

/// Strip RFC 7230 §3.2.4 OWS — space (0x20) and horizontal tab (0x09) —
/// from both ends of `value`. Mirrors what the parser strips on the wire
/// side; using `string.trim` would also strip Unicode whitespace, which
/// is over-broad for an HTTP-style header.
fn trim_ows(value: String) -> String {
  value |> drop_leading_ows |> drop_trailing_ows
}

fn drop_leading_ows(value: String) -> String {
  case string.pop_grapheme(value) {
    Ok(#(" ", rest)) | Ok(#("\t", rest)) -> drop_leading_ows(rest)
    _ -> value
  }
}

fn drop_trailing_ows(value: String) -> String {
  use <- bool.guard(
    when: !{ string.ends_with(value, " ") || string.ends_with(value, "\t") },
    return: value,
  )
  drop_trailing_ows(string.drop_end(value, 1))
}

fn valid_header_name(name: String) -> Bool {
  !{
    string.contains(name, "\r")
    || string.contains(name, "\n")
    || string.contains(name, "\u{0000}")
    || string.contains(name, ":")
  }
}

fn valid_header_value(value: String) -> Bool {
  !{
    string.contains(value, "\r")
    || string.contains(value, "\n")
    || string.contains(value, "\u{0000}")
  }
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

/// Structural equality on the wire-level content of two `Part` values.
///
/// Compares the headers list (preserving order, with case-sensitive
/// name matching that mirrors RFC 7578 §4.2) and the body bytes. The
/// convenience cache fields — `name`, `filename`, `content_type` — are
/// intentionally ignored because they are derived from the headers
/// and may differ between a `Part.new/5`-constructed value (where the
/// caller passes the cache) and a parsed `Part` (where the parser
/// derives the cache from `Content-Disposition` / `Content-Type`).
/// Two `Part`s that `equal_on_wire` returns `True` for will encode
/// to the same bytes via `multipartkit.encode/2` (modulo the
/// boundary string, which is supplied at encode time).
///
/// Use this for property-style round-trip tests where the caller
/// passes one `Part` shape into the encoder and gets another
/// (cache-derived) shape back from the parser.
pub fn equal_on_wire(a: Part, b: Part) -> Bool {
  a.headers == b.headers && a.body == b.body
}

/// `equal_on_wire` lifted over a pair of `Part` lists. Returns `True`
/// when the lists have the same length and every paired element
/// satisfies `equal_on_wire`.
pub fn list_equal_on_wire(a: List(Part), b: List(Part)) -> Bool {
  case a, b {
    [], [] -> True
    [], _ -> False
    _, [] -> False
    [first_a, ..rest_a], [first_b, ..rest_b] ->
      case equal_on_wire(first_a, first_b) {
        True -> list_equal_on_wire(rest_a, rest_b)
        False -> False
      }
  }
}

fn find_header(headers: List(#(String, String)), name: String) -> List(String) {
  list.filter_map(headers, fn(entry) {
    case text.equals_ci(entry.0, name) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}
