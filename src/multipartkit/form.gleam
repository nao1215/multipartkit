import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import multipartkit/infer
import multipartkit/internal/disposition
import multipartkit/part.{type Part}

/// Opaque builder for multipart/form-data messages.
///
/// `Form` is constructed via `new` and accumulated with `add_field` /
/// `add_file` / `add_file_auto` / `unsafe_add_part`. Read it back as
/// `List(Part)` via `parts`. The boundary is generated lazily by
/// `encode_form` and is not part of `Form`'s observable state.
pub opaque type Form {
  Form(reversed_parts: List(Part))
}

/// Reasons the strict form-builder variants reject input.
///
/// The non-strict `add_field` / `add_file` / `add_file_auto` /
/// `add_file_auto_with` silently strip CR / LF / NUL bytes from
/// the values that flow into header lines (sealing the #28 header
/// injection vector). The silent strip is data loss the caller
/// cannot observe — `add_field("name\n", _)` produces a part renamed
/// to `"_unnamed_<n>"` (the lenient path never emits `name=""`; see
/// `add_field`), and `add_file(_, "fi\nle.png", _, _)` concatenates
/// the two halves into a different valid filename. The `*_strict`
/// variants surface this as a typed error so callers can render
/// "field name `foo\\nbar` contains forbidden control bytes"
/// rather than silently producing the wrong wire. (#40, #41)
pub type FormError {
  /// `add_field_strict` saw CR / LF / NUL bytes in the field name.
  /// Carries the original (un-sanitized) value.
  NameContainsControlBytes(value: String)
  /// `add_file_strict` saw CR / LF / NUL bytes in the file's
  /// filename. Carries the original (un-sanitized) value.
  FilenameContainsControlBytes(value: String)
  /// `add_file_strict` saw CR / LF / NUL bytes in the file's
  /// content type. Carries the original (un-sanitized) value.
  ContentTypeContainsControlBytes(value: String)
  /// `add_field_strict` / `add_file_strict` saw an empty (or
  /// whitespace-only) field name. RFC 7578 §4.2 requires the
  /// `Content-Disposition` `name` parameter to be the field name,
  /// and an empty name produces a wire image whose interpretation
  /// is implementation-defined at the receiver (some servers skip
  /// the field, some overwrite siblings keyed on `""`, some reject
  /// the whole body). Carries the original (un-trimmed) value so
  /// callers can render diagnostics. (#51)
  EmptyFieldName(value: String)
}

/// A new empty form.
pub fn new() -> Form {
  Form(reversed_parts: [])
}

/// Append a text field. `value` is encoded as UTF-8 in the part body. No
/// filename is set.
///
/// RFC 7578 §4.2 requires the `Content-Disposition` `name` parameter
/// to be non-empty (it is the field name itself). This non-strict
/// variant does **not** reject a bad `name` — it silently strips CR /
/// LF / NUL bytes to prevent header injection. To guarantee the
/// resulting part is always RFC 7578-addressable, a `name` that is
/// empty (or becomes empty / whitespace-only after the strip) is
/// replaced with a generated placeholder `"_unnamed_<n>"`, where `<n>`
/// is the part's zero-based position in the form. This means the
/// observable `name` is **never** `""` — `add_field("", _)` and
/// `add_field("name\n", _)` both produce a part named `"_unnamed_0"`
/// rather than a silently empty-named part whose receiver
/// interpretation is implementation-defined (#57, #58). The rename is
/// still a loss the caller cannot prevent here, so callers passing
/// user-typed or upstream data into `name` should prefer
/// `add_field_strict`, which surfaces both failure modes as typed
/// errors (`EmptyFieldName(value:)` and `NameContainsControlBytes(value:)`)
/// instead of renaming. The cached `name` on the resulting `Part`
/// reflects the placeholder and survives a parse-after-encode round-trip
/// unchanged. The placeholder is position-based, not collision-proof: a
/// caller who also passes a literal `"_unnamed_<k>"` as a real field name
/// can end up with two parts sharing that name. Use `unsafe_add_part` if
/// byte-exact preservation of arbitrary header values is required.
pub fn add_field(form: Form, name name: String, value value: String) -> Form {
  let safe_name = ensure_named(form, disposition.sanitize_value(name))
  let header = #(
    "Content-Disposition",
    disposition.build_form_data_value(safe_name, None),
  )
  let new_part =
    part.unchecked_new(
      headers: [header],
      name: Some(safe_name),
      filename: None,
      content_type: None,
      body: <<value:utf8>>,
    )
  push(form, new_part)
}

/// Append a file part with an explicit content type.
///
/// RFC 7578 §4.2 requires the `Content-Disposition` `name` parameter
/// to be non-empty (the `filename` parameter may legitimately be
/// empty). This non-strict variant does **not** enforce the
/// non-empty `name` rule — it silently accepts `""` and also
/// silently strips CR / LF / NUL bytes from `name`, `filename`, and
/// `content_type` to prevent header injection. The cached `name`,
/// `filename`, and `content_type` on the resulting `Part` reflect
/// the sanitized values. The strip on `filename` is especially
/// dangerous — `add_file(_, "fi\nle.png", _, _)` concatenates the
/// two halves into the *different valid filename* `"file.png"`,
/// which can change authorisation-relevant identifiers. Callers
/// passing user-typed or upstream data should prefer
/// `add_file_strict`, which surfaces the bad input as
/// `Error(EmptyFieldName(value:))` /
/// `Error(NameContainsControlBytes(value:))` /
/// `Error(FilenameContainsControlBytes(value:))` /
/// `Error(ContentTypeContainsControlBytes(value:))`. Use
/// `unsafe_add_part` if byte-exact preservation of arbitrary header
/// values is required.
pub fn add_file(
  form: Form,
  name name: String,
  filename filename: String,
  content_type content_type: String,
  body body: BitArray,
) -> Form {
  push(form, build_file_part(name, filename, content_type, body))
}

/// Append a file part using the default (no-op) inferer.
///
/// Equivalent to `add_file_auto_with(form, name, filename, body,
/// infer.default_inferer())`. The default inferer returns `None` from both
/// helpers in v0.1.0, so this falls through to `application/octet-stream`
/// unless you call `add_file_auto_with` with a real inferer.
pub fn add_file_auto(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
) -> Form {
  add_file_auto_with(form, name, filename, body, infer.default_inferer())
}

/// Append a file part, inferring the content type via the supplied
/// `Inferer`.
///
/// Inference precedence:
///
/// 1. `inferer.from_filename(filename)`
/// 2. `inferer.from_bytes(body)`
/// 3. `application/octet-stream`
///
/// The inferred content type is sanitized (CR / LF / NUL stripped) before
/// being written to the header.
pub fn add_file_auto_with(
  form: Form,
  name: String,
  filename: String,
  body: BitArray,
  inferer: infer.Inferer,
) -> Form {
  let content_type = case inferer.from_filename(filename) {
    Some(value) -> value
    None ->
      case inferer.from_bytes(body) {
        Some(value) -> value
        None -> "application/octet-stream"
      }
  }
  add_file(form, name:, filename:, content_type:, body:)
}

/// Strict counterpart of `add_field`: rejects names containing CR /
/// LF / NUL bytes with `Error(NameContainsControlBytes(value:))`,
/// and rejects empty or whitespace-only names with
/// `Error(EmptyFieldName(value:))`.
///
/// The non-strict `add_field` silently strips control bytes (so
/// `add_field("name\n", _)` produces a part with `name=""`), and
/// also silently accepts a truly empty `name`. RFC 7578 §4.2
/// requires the `Content-Disposition` `name` parameter to be the
/// field name; an empty name produces a wire image whose
/// interpretation is implementation-defined at the receiver. For
/// callers that pass user-typed or upstream data into `name` and
/// want to surface bad inputs as a typed error rather than silent
/// data loss, use this variant. The `value` payload carries the
/// caller's original input so the error renders as
/// "field name `foo\\nbar` contains forbidden control bytes" or
/// "field name `   ` is empty". (#40, #51)
pub fn add_field_strict(
  form: Form,
  name name: String,
  value value: String,
) -> Result(Form, FormError) {
  use <- bool.guard(
    when: string.trim(name) == "",
    return: Error(EmptyFieldName(value: name)),
  )
  use <- bool.guard(
    when: disposition.has_header_breaking_bytes(name),
    return: Error(NameContainsControlBytes(value: name)),
  )
  Ok(add_field(form, name:, value:))
}

/// Strict counterpart of `add_file`: rejects names, filenames, and
/// content types containing CR / LF / NUL bytes with the matching
/// `FormError` variant, and rejects an empty or whitespace-only
/// `name` with `Error(EmptyFieldName(value:))`. (`filename` may
/// legitimately be empty — only `name` is required to be
/// non-empty per RFC 7578 §4.2.)
///
/// The non-strict `add_file` silently strips control bytes. For
/// `name` the strip leaves an empty string (loud round-trip
/// failure); for `filename` it concatenates the two halves into a
/// *different valid filename*, which can change
/// authorisation-relevant identifiers (the attacker shape
/// described in #41). The strict variant catches both at the
/// builder boundary so the wrong wire never gets produced.
/// (#41, #51)
pub fn add_file_strict(
  form: Form,
  name name: String,
  filename filename: String,
  content_type content_type: String,
  body body: BitArray,
) -> Result(Form, FormError) {
  use <- bool.guard(
    when: string.trim(name) == "",
    return: Error(EmptyFieldName(value: name)),
  )
  use <- bool.guard(
    when: disposition.has_header_breaking_bytes(name),
    return: Error(NameContainsControlBytes(value: name)),
  )
  use <- bool.guard(
    when: disposition.has_header_breaking_bytes(filename),
    return: Error(FilenameContainsControlBytes(value: filename)),
  )
  use <- bool.guard(
    when: disposition.has_header_breaking_bytes(content_type),
    return: Error(ContentTypeContainsControlBytes(value: content_type)),
  )
  Ok(add_file(form, name:, filename:, content_type:, body:))
}

/// Append a pre-built `Part` without validation or normalisation.
///
/// The caller is responsible for keeping `headers`, `name`, `filename`, and
/// `content_type` mutually consistent. Prefer `add_field` / `add_file` /
/// `add_file_auto` for library-maintained consistency.
pub fn unsafe_add_part(form: Form, the_part: Part) -> Form {
  push(form, the_part)
}

/// Read the parts in insertion order.
pub fn parts(form: Form) -> List(Part) {
  list.reverse(form.reversed_parts)
}

fn push(form: Form, the_part: Part) -> Form {
  Form(reversed_parts: [the_part, ..form.reversed_parts])
}

/// Guarantee a non-empty field name for the lenient (`add_field`)
/// builder path. `safe_name` is the value after CR / LF / NUL stripping.
/// RFC 7578 §4.2 requires the `name` parameter to be the field name; an
/// empty name produces a wire image whose receiver interpretation is
/// implementation-defined. Rather than emit `name=""`, replace an empty
/// (or whitespace-only) name with `"_unnamed_<n>"`, where `<n>` is the
/// zero-based position the new part will occupy. A name that is merely
/// padded (e.g. `" a "`) is kept as-is — only an entirely blank name is
/// rewritten. (#57, #58)
fn ensure_named(form: Form, safe_name: String) -> String {
  use <- bool.guard(when: string.trim(safe_name) != "", return: safe_name)
  "_unnamed_" <> int.to_string(list.length(form.reversed_parts))
}

fn build_file_part(
  name: String,
  filename: String,
  content_type: String,
  body: BitArray,
) -> Part {
  let safe_name = disposition.sanitize_value(name)
  let safe_filename = disposition.sanitize_value(filename)
  let safe_content_type = disposition.sanitize_value(content_type)
  let disposition_header = #(
    "Content-Disposition",
    disposition.build_form_data_value(safe_name, Some(safe_filename)),
  )
  let content_type_header = #("Content-Type", safe_content_type)
  part.unchecked_new(
    headers: [disposition_header, content_type_header],
    name: Some(safe_name),
    filename: Some(safe_filename),
    content_type: Some(safe_content_type),
    body: body,
  )
}
