import gleam/option.{type Option, None}

/// Optional content-type inference from a filename.
///
/// The default v0.1.0 implementation always returns `None`. Wire `mimetype`
/// (or another inferer) in via the host application to enable inference.
pub fn content_type_from_filename(_filename: String) -> Option(String) {
  None
}

/// Optional content-type inference from a body byte sequence.
///
/// Same default-`None` policy as `content_type_from_filename`.
pub fn content_type_from_bytes(_body: BitArray) -> Option(String) {
  None
}
