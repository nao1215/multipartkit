//// Regression tests for Issue #50: `multipartkit.parse_content_disposition`
//// quoted-pair handling must align with RFC 7230 §3.2.6
////
////   quoted-pair = "\" ( HTAB / SP / VCHAR / obs-text )
////
//// where `VCHAR = %x21-7E` and `obs-text = %x80-FF`. A `\X` whose `X`
//// is outside that set (NUL, CR, LF, other control bytes, or DEL)
//// must be rejected with `Error(InvalidQuotedPair(...))` rather than
//// silently dropping the backslash — otherwise an attacker can smuggle
//// a NUL byte into a decoded `name` / `filename`.

import gleam/option.{Some}
import gleeunit/should
import multipartkit

// === RFC 7230 §3.2.6 strict compliance ===

pub fn cd_canonical_escape_backslash_test() {
  let assert Ok(p) =
    multipartkit.parse_content_disposition("form-data; name=\"\\\\backslash\"")
  p.name |> should.equal(Some("\\backslash"))
}

pub fn cd_canonical_escape_quote_test() {
  let assert Ok(p) =
    multipartkit.parse_content_disposition("form-data; name=\"\\\"quoted\\\"\"")
  p.name |> should.equal(Some("\"quoted\""))
}

pub fn cd_vchar_escape_drops_backslash_test() {
  // \X where X is VCHAR ('n' = U+006E ∈ [%x21-7E])
  // RFC 7230: \X 展開 = X (backslash drop)
  let assert Ok(p) =
    multipartkit.parse_content_disposition("form-data; name=\"\\nnewline\"")
  p.name |> should.equal(Some("nnewline"))
}

pub fn cd_nul_in_quoted_pair_rejected_test() {
  // \X where X is NUL (U+0000): not VCHAR, not obs-text → invalid quoted-pair
  case
    multipartkit.parse_content_disposition("form-data; name=\"\\\u{0000}nul\"")
  {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn cd_cr_in_quoted_pair_rejected_test() {
  case multipartkit.parse_content_disposition("form-data; name=\"\\\rcr\"") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn cd_lf_in_quoted_pair_rejected_test() {
  case multipartkit.parse_content_disposition("form-data; name=\"\\\nlf\"") {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

// === Behavioural regression baseline ===

pub fn cd_no_escape_test() {
  let assert Ok(p) =
    multipartkit.parse_content_disposition("form-data; name=\"plain\"")
  p.name |> should.equal(Some("plain"))
}

pub fn cd_utf8_name_test() {
  let assert Ok(p) =
    multipartkit.parse_content_disposition("form-data; name=\"日本語\"")
  p.name |> should.equal(Some("日本語"))
}
