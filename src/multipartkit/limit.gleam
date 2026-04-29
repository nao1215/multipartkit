/// Limits applied during parsing to bound resource consumption.
///
/// All limits are inclusive: a value equal to the limit is allowed; the
/// `(limit + 1)`-th byte / part triggers the error.
pub type Limits {
  Limits(
    /// Total bytes consumed from input, including boundary delimiters,
    /// preamble, epilogue, and per-part header blocks. Triggers
    /// `BodyTooLarge`.
    max_body_bytes: Int,
    /// Bytes of a single part body excluding the part's header block and the
    /// surrounding boundary lines. Triggers `PartTooLarge`.
    max_part_bytes: Int,
    /// Maximum number of parts produced. Triggers `TooManyParts` when the
    /// `(limit + 1)`-th part is detected.
    max_parts: Int,
    /// Total bytes of one part's complete header block, measured from the
    /// byte after the boundary delimiter line up to and including the blank
    /// line that terminates the header block. Triggers `HeaderTooLarge`.
    max_header_bytes: Int,
  )
}

/// Conservative defaults used by `parse` and `parse_stream` when no explicit
/// limits are supplied.
pub fn default_limits() -> Limits {
  Limits(
    max_body_bytes: 10_000_000,
    max_part_bytes: 5_000_000,
    max_parts: 100,
    max_header_bytes: 16_384,
  )
}
