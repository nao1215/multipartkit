import gleam/option.{None, Some}
import gleeunit/should
import multipartkit.{InvalidContentDisposition}

pub fn parse_form_data_basic_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("form-data; name=\"title\"")
  parsed.disposition |> should.equal("form-data")
  parsed.name |> should.equal(Some("title"))
  parsed.filename |> should.equal(None)
}

pub fn parse_normalises_disposition_case_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("Form-Data; name=\"title\"")
  parsed.disposition |> should.equal("form-data")
}

pub fn parse_attachment_disposition_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("attachment; filename=\"a.txt\"")
  parsed.disposition |> should.equal("attachment")
  parsed.filename |> should.equal(Some("a.txt"))
}

pub fn parse_form_data_with_filename_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"upload\"; filename=\"photo.jpg\"",
    )
  parsed.name |> should.equal(Some("upload"))
  parsed.filename |> should.equal(Some("photo.jpg"))
}

pub fn parse_quoted_string_with_escapes_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("form-data; name=\"a\\\"b\\\\c\"")
  parsed.name |> should.equal(Some("a\"b\\c"))
}

pub fn parse_filename_with_spaces_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"upload\"; filename=\"my file.txt\"",
    )
  parsed.filename |> should.equal(Some("my file.txt"))
}

pub fn parse_filename_star_utf8_test() {
  // RFC 5987 example: filename*=UTF-8''r%C3%A9sum%C3%A9.txt
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"file\"; filename*=UTF-8''r%C3%A9sum%C3%A9.txt",
    )
  parsed.filename |> should.equal(Some("résumé.txt"))
}

pub fn parse_filename_star_iso_8859_1_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"file\"; filename*=ISO-8859-1''na%EFve.txt",
    )
  parsed.filename |> should.equal(Some("naïve.txt"))
}

pub fn parse_filename_star_takes_precedence_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"x\"; filename=\"plain.txt\"; filename*=UTF-8''star.txt",
    )
  parsed.filename |> should.equal(Some("star.txt"))
}

pub fn parse_filename_star_unsupported_charset_is_ignored_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"x\"; filename=\"plain.txt\"; filename*=BIG5''something",
    )
  parsed.filename |> should.equal(Some("plain.txt"))
}

pub fn parse_filename_star_invalid_pct_is_ignored_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"x\"; filename*=UTF-8''%ZZbad",
    )
  parsed.filename |> should.equal(None)
}

pub fn parse_unparseable_returns_error_test() {
  let assert Error(InvalidContentDisposition(value)) =
    multipartkit.parse_content_disposition("nope; nope")
  value |> should.equal("nope; nope")
}

pub fn parse_preserves_param_order_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; gamma=1; beta=\"two\"; alpha=3",
    )
  parsed.parameters
  |> should.equal([#("gamma", "1"), #("beta", "two"), #("alpha", "3")])
}

pub fn parse_rejects_a_repeated_parameter_test() {
  // RFC 6266 §4.1: a repeated parameter makes the value invalid.
  let value = "form-data; name=\"first\"; name=\"second\""
  multipartkit.parse_content_disposition(value)
  |> should.equal(Error(InvalidContentDisposition(value)))
}

pub fn parse_empty_disposition_token_rejected_test() {
  let assert Error(InvalidContentDisposition(_)) =
    multipartkit.parse_content_disposition(";name=x")
}

pub fn parse_tolerates_no_params_test() {
  let assert Ok(parsed) = multipartkit.parse_content_disposition("inline")
  parsed.disposition |> should.equal("inline")
  parsed.name |> should.equal(None)
  parsed.filename |> should.equal(None)
  parsed.parameters |> should.equal([])
}

pub fn parse_filename_empty_quoted_test() {
  // HTML5 unselected file input: filename=""
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "form-data; name=\"upload\"; filename=\"\"",
    )
  parsed.filename |> should.equal(Some(""))
}
