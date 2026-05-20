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
/// import gleam/option.{type Option, None, Some}
/// import mimetype
/// import multipartkit/form.{type Form}
/// import multipartkit/infer.{type Inferer, Inferer}
///
/// pub fn upload_with_mimetype(
///   form_value: Form,
///   filename: String,
///   bytes: BitArray,
/// ) -> Form {
///   let from_filename = fn(name: String) -> Option(String) {
///     case mimetype.filename_to_mime_type_strict(name) {
///       Ok(value) -> Some(value)
///       Error(_) -> None
///     }
///   }
///   let from_bytes = fn(body: BitArray) -> Option(String) {
///     case mimetype.detect_strict(body) {
///       Ok(value) -> Some(value)
///       Error(_) -> None
///     }
///   }
///   let inferer = Inferer(from_filename: from_filename, from_bytes: from_bytes)
///   form.add_file_auto_with(form_value, "upload", filename, bytes, inferer)
/// }
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
/// This is the default no-op of multipartkit's pluggable inference
/// interface: it **always returns `None`** for every input, including
/// well-known extensions like `"photo.png"` or `"doc.pdf"`. multipartkit
/// deliberately ships no built-in extension table so the library has zero
/// inference dependencies; callers who want real inference wire one in via
/// `form.add_file_auto_with` (the function this helper exists to compose
/// with). Calling this function directly is rarely what you want — it
/// exists mainly so the `Inferer` shape stays uniform whether or not a
/// real inferer is wired in.
///
/// To get actual inference, build an `Inferer` from `nao1215/mimetype`
/// (or any other inference library) and pass it to
/// `form.add_file_auto_with`:
///
/// ```gleam
/// import gleam/option.{type Option, None, Some}
/// import mimetype
/// import multipartkit/form
/// import multipartkit/infer.{type Inferer, Inferer}
///
/// let inferer =
///   Inferer(
///     from_filename: fn(name) {
///       case mimetype.filename_to_mime_type_strict(name) {
///         Ok(value) -> Some(value)
///         Error(_) -> None
///       }
///     },
///     from_bytes: fn(body) {
///       case mimetype.detect_strict(body) {
///         Ok(value) -> Some(value)
///         Error(_) -> None
///       }
///     },
///   )
/// form.add_file_auto_with(my_form, "upload", "photo.png", bytes, inferer)
/// ```
///
/// See also `examples/mimetype_inference` for a runnable wiring.
pub fn content_type_from_filename(filename: String) -> Option(String) {
  default_inferer().from_filename(filename)
}

/// Optional content-type inference from a body byte sequence.
///
/// Same documented default-no-op policy as `content_type_from_filename`:
/// this **always returns `None`** for every input, including well-known
/// magic-byte signatures like the 8-byte PNG header. Wire `nao1215/mimetype`
/// (or another inferer) in via `form.add_file_auto_with` for actual
/// inference — see the docstring on `content_type_from_filename` for a
/// worked example.
pub fn content_type_from_bytes(body: BitArray) -> Option(String) {
  default_inferer().from_bytes(body)
}
