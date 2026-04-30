import gleam/bool
import gleam/result

/// Limits applied during parsing to bound resource consumption.
///
/// All limits are inclusive: a value equal to the limit is allowed; the
/// `(limit + 1)`-th byte / part triggers the error.
///
/// `Limits` is an opaque type. Construct via `new` (validated,
/// recommended) or `default_limits` (conservative presets), and inspect
/// values through the `max_body_bytes` / `max_part_bytes` / `max_parts` /
/// `max_header_bytes` accessor functions — direct field access was
/// available in pre-1.0 releases but has been removed so the
/// representation can evolve without breaking external callers.
pub opaque type Limits {
  Limits(
    max_body_bytes: Int,
    max_part_bytes: Int,
    max_parts: Int,
    max_header_bytes: Int,
  )
}

/// Why a `Limits` value could not be constructed.
///
/// Returned by `new` when a field receives a non-positive value.
/// `field` names the offending field so a single handler can produce a
/// meaningful error message even when several limits are misconfigured
/// at once (the first failing field stops further checks).
pub type LimitConfigError {
  NonPositiveLimit(field: String, given: Int)
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

/// Construct a `Limits` value with validation. Each field must be `>= 1`;
/// otherwise the returned `Error` names the first failing field.
///
/// Use this in any path where the limit values come from configuration,
/// CLI flags, request input, or other dynamic input. For trusted
/// constants the direct `Limits(...)` constructor is also fine, but
/// callers that want a stable surface ahead of the `Limits` type being
/// closed (see the upcoming opaque-type work) should prefer `new`.
///
/// Example:
///   import multipartkit/limit
///
///   case limit.new(
///     max_body_bytes: 5_000_000,
///     max_part_bytes: 2_000_000,
///     max_parts: 50,
///     max_header_bytes: 8_192,
///   ) {
///     Ok(limits) -> ...
///     Error(limit.NonPositiveLimit(field: f, given: g)) -> ...
///   }
pub fn new(
  max_body_bytes max_body_bytes: Int,
  max_part_bytes max_part_bytes: Int,
  max_parts max_parts: Int,
  max_header_bytes max_header_bytes: Int,
) -> Result(Limits, LimitConfigError) {
  use _ <- result.try(check_positive("max_body_bytes", max_body_bytes))
  use _ <- result.try(check_positive("max_part_bytes", max_part_bytes))
  use _ <- result.try(check_positive("max_parts", max_parts))
  use _ <- result.try(check_positive("max_header_bytes", max_header_bytes))
  Ok(Limits(
    max_body_bytes: max_body_bytes,
    max_part_bytes: max_part_bytes,
    max_parts: max_parts,
    max_header_bytes: max_header_bytes,
  ))
}

fn check_positive(field: String, value: Int) -> Result(Nil, LimitConfigError) {
  use <- bool.guard(
    value < 1,
    Error(NonPositiveLimit(field: field, given: value)),
  )
  Ok(Nil)
}

/// Total-input byte budget. See `Limits.max_body_bytes`.
pub fn max_body_bytes(limits: Limits) -> Int {
  limits.max_body_bytes
}

/// Per-part body byte budget. See `Limits.max_part_bytes`.
pub fn max_part_bytes(limits: Limits) -> Int {
  limits.max_part_bytes
}

/// Maximum number of parts. See `Limits.max_parts`.
pub fn max_parts(limits: Limits) -> Int {
  limits.max_parts
}

/// Per-part header-block byte budget. See `Limits.max_header_bytes`.
pub fn max_header_bytes(limits: Limits) -> Int {
  limits.max_header_bytes
}
