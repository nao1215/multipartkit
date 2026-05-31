import gleam/option.{type Option, None}
import mimetype

/// A pair of content-type inferers that callers can wire into
/// `form.add_file_auto_with`.
///
/// `from_filename` is consulted first; if it returns `None`, `from_bytes`
/// is tried next; if both return `None`, the host falls back to
/// `application/octet-stream`.
///
/// Two ready-made inferers are provided: `default_inferer` (a no-op that
/// always returns `None`, so `add_file_auto` falls through to
/// `application/octet-stream`) and `builtin_inferer` (backed by the
/// built-in `content_type_from_filename` / `content_type_from_bytes`,
/// which resolve well-known extensions and magic-byte signatures via
/// `nao1215/mimetype`). Pass whichever you want to
/// `form.add_file_auto_with`, or supply your own:
///
/// ```gleam
/// import multipartkit/form
/// import multipartkit/infer
///
/// pub fn upload(form_value, filename, bytes) {
///   // Resolve image/png, application/pdf, etc. out of the box.
///   form.add_file_auto_with(form_value, "upload", filename, bytes, infer.builtin_inferer())
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
/// `add_file_auto_with` (for example `builtin_inferer`, or one of your
/// own). Keeping the default a no-op means `add_file_auto` never changes
/// the content type implicitly — inference is always something the caller
/// opts into.
pub fn default_inferer() -> Inferer {
  Inferer(from_filename: noop_filename, from_bytes: noop_bytes)
}

fn noop_filename(_filename: String) -> Option(String) {
  None
}

fn noop_bytes(_body: BitArray) -> Option(String) {
  None
}

/// Inferer backed by the built-in `content_type_from_filename` and
/// `content_type_from_bytes` helpers (which delegate to
/// `nao1215/mimetype`).
///
/// Pass this to `form.add_file_auto_with` to get content-type inference
/// for well-known extensions and magic-byte signatures without writing
/// the `mimetype` wiring yourself:
///
/// ```gleam
/// form.add_file_auto_with(my_form, "upload", "photo.png", bytes, infer.builtin_inferer())
/// // -> the part's Content-Type is image/png
/// ```
pub fn builtin_inferer() -> Inferer {
  Inferer(
    from_filename: content_type_from_filename,
    from_bytes: content_type_from_bytes,
  )
}

/// Infer a content type from a filename's extension.
///
/// Delegates to `nao1215/mimetype`'s extension database: returns
/// `Some(mime)` for a recognised extension (for example `"photo.png"` ->
/// `Some("image/png")`, `"doc.pdf"` -> `Some("application/pdf")`,
/// `"data.json"` -> `Some("application/json")`) and `None` when the path
/// has no usable extension (`""`, `"README"`) or the extension is not in
/// the database (`"a.zzznosuch"`).
///
/// This is a convenience over the `mimetype` dependency; for the form
/// builder, wire it in with `form.add_file_auto_with(form, ...,
/// builtin_inferer())` (or build your own `Inferer`).
pub fn content_type_from_filename(filename: String) -> Option(String) {
  mimetype.filename_to_mime_type_strict(filename)
  |> option.from_result
  |> option.map(mimetype.essence_of)
}

/// Infer a content type from a body's leading bytes (magic-number
/// signature).
///
/// Delegates to `nao1215/mimetype`'s detector: returns `Some(mime)` for a
/// recognised signature (for example the 8-byte PNG header ->
/// `Some("image/png")`, `<<0xFF, 0xD8, 0xFF, ...>>` ->
/// `Some("image/jpeg")`, `"%PDF-..."` -> `Some("application/pdf")`) and
/// `None` for the empty `BitArray` or input whose bytes match no
/// supported signature. Note `mimetype`'s detector classifies arbitrary
/// printable-ASCII input as `Some("text/plain")`, so a text body with no
/// stronger signature resolves to `text/plain` rather than `None`.
///
/// As with `content_type_from_filename`, this is a convenience over the
/// `mimetype` dependency; wire it into the form builder with
/// `form.add_file_auto_with(form, ..., builtin_inferer())`.
pub fn content_type_from_bytes(body: BitArray) -> Option(String) {
  mimetype.detect_strict(body)
  |> option.from_result
  |> option.map(mimetype.essence_of)
}
