import gleam/option.{type Option, None}

/// A pair of content-type inferers that callers can wire into
/// `form.add_file_auto_with`.
///
/// `from_filename` is consulted first; if it returns `None`, `from_bytes`
/// is tried next; if both return `None`, the host falls back to
/// `application/octet-stream`.
///
/// The default inferer returns `None` from both functions, so by default
/// `add_file_auto` always falls through to `application/octet-stream`.
/// Wire `nao1215/mimetype` (or any other inference library) by passing an
/// `Inferer` to `form.add_file_auto_with`:
///
/// ```gleam
/// import gleam/option.{None, Some}
/// import mimetype
/// import multipartkit/form
/// import multipartkit/infer.{Inferer}
///
/// let mimetype_inferer =
///   Inferer(
///     from_filename: fn(name) {
///       case mimetype.filename_to_mime_type_strict(name) {
///         Ok(value) -> Some(value)
///         Error(_) -> None
///       }
///     },
///     from_bytes: fn(bytes) {
///       case mimetype.detect_strict(bytes) {
///         Ok(value) -> Some(value)
///         Error(_) -> None
///       }
///     },
///   )
///
/// form.add_file_auto_with(form_value, "upload", "x.png", bytes, mimetype_inferer)
/// ```
pub type Inferer {
  Inferer(
    from_filename: fn(String) -> Option(String),
    from_bytes: fn(BitArray) -> Option(String),
  )
}

/// Inferer that always returns `None`.
///
/// `add_file_auto` uses this and therefore always emits
/// `application/octet-stream` unless the host swaps in a real inferer via
/// `add_file_auto_with`.
pub fn default_inferer() -> Inferer {
  Inferer(from_filename: noop_filename, from_bytes: noop_bytes)
}

fn noop_filename(_filename: String) -> Option(String) {
  None
}

fn noop_bytes(_body: BitArray) -> Option(String) {
  None
}

/// Optional content-type inference from a filename.
///
/// The default v0.1.0 implementation always returns `None`. Wire `mimetype`
/// (or another inferer) in via `form.add_file_auto_with` to enable
/// inference.
pub fn content_type_from_filename(filename: String) -> Option(String) {
  default_inferer().from_filename(filename)
}

/// Optional content-type inference from a body byte sequence.
///
/// Same default-`None` policy as `content_type_from_filename`.
pub fn content_type_from_bytes(body: BitArray) -> Option(String) {
  default_inferer().from_bytes(body)
}
