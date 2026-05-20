//// Regression tests for Issue #51: `multipartkit/form.add_field_strict`
//// and `add_file_strict` must reject empty (or whitespace-only) field
//// names with `Error(EmptyFieldName(value:))`.
////
//// RFC 7578 §4.2 says the `Content-Disposition` `name` parameter is the
//// *field name*, and an empty name produces a wire image whose
//// interpretation is implementation-defined at the receiver (skip,
//// overwrite siblings keyed on `""`, or reject the whole body). The
//// non-strict `add_field` / `add_file` silently accept `""` for
//// backward compatibility; the strict variants must surface it.

import gleeunit/should
import multipartkit
import multipartkit/form

// === add_field_strict: empty name rejected ===

pub fn add_field_strict_empty_name_rejected_test() {
  case form.add_field_strict(form.new(), "", "value") {
    Error(form.EmptyFieldName(value: "")) -> Nil
    _ -> should.fail()
  }
}

pub fn add_field_strict_whitespace_only_name_rejected_test() {
  case form.add_field_strict(form.new(), "   ", "value") {
    Error(form.EmptyFieldName(value: "   ")) -> Nil
    _ -> should.fail()
  }
}

pub fn add_field_strict_tab_only_name_rejected_test() {
  case form.add_field_strict(form.new(), "\t\t", "value") {
    Error(form.EmptyFieldName(value: "\t\t")) -> Nil
    _ -> should.fail()
  }
}

// === add_file_strict: empty name rejected ===

pub fn add_file_strict_empty_name_rejected_test() {
  case
    form.add_file_strict(form.new(), "", "file.txt", "text/plain", <<"hi">>)
  {
    Error(form.EmptyFieldName(value: "")) -> Nil
    _ -> should.fail()
  }
}

pub fn add_file_strict_whitespace_only_name_rejected_test() {
  case
    form.add_file_strict(form.new(), "  ", "file.txt", "text/plain", <<"hi">>)
  {
    Error(form.EmptyFieldName(value: "  ")) -> Nil
    _ -> should.fail()
  }
}

// === add_file_strict: empty filename is still allowed ===

pub fn add_file_strict_empty_filename_allowed_test() {
  // Per RFC 7578 §4.2 only `name` is required; `filename` may be empty.
  case form.add_file_strict(form.new(), "name", "", "text/plain", <<"hi">>) {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }
}

// === Non-empty name still works (regression baseline) ===

pub fn add_field_strict_normal_name_works_test() {
  case form.add_field_strict(form.new(), "name", "value") {
    Ok(f) -> {
      let #(_ct, _body) = multipartkit.encode_form(f)
      Nil
    }
    Error(_) -> should.fail()
  }
}

pub fn add_file_strict_normal_name_works_test() {
  case
    form.add_file_strict(form.new(), "field", "file.txt", "text/plain", <<
      "hi",
    >>)
  {
    Ok(f) -> {
      let #(_ct, _body) = multipartkit.encode_form(f)
      Nil
    }
    Error(_) -> should.fail()
  }
}

// === Non-strict add_field still silently accepts (backward compat) ===

pub fn add_field_non_strict_empty_name_still_accepted_test() {
  // Backward-compatibility pin: the non-strict variant must not gain
  // a hidden reject in this release.
  let f = form.add_field(form.new(), "", "value")
  case form.parts(f) {
    [_one] -> Nil
    _ -> should.fail()
  }
}
