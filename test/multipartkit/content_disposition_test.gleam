import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/content_disposition
import multipartkit/error.{InvalidContentDisposition}

pub fn parse_form_data_basic_test() {
  let assert Ok(parsed) = content_disposition.parse("form-data; name=\"title\"")
  content_disposition.disposition(parsed) |> should.equal("form-data")
  content_disposition.name(parsed) |> should.equal(Some("title"))
  content_disposition.filename(parsed) |> should.equal(None)
}

pub fn parse_normalises_disposition_case_test() {
  let assert Ok(parsed) = content_disposition.parse("Form-Data; name=\"title\"")
  content_disposition.disposition(parsed) |> should.equal("form-data")
}

pub fn parse_attachment_disposition_test() {
  let assert Ok(parsed) =
    content_disposition.parse("attachment; filename=\"a.txt\"")
  content_disposition.disposition(parsed) |> should.equal("attachment")
  content_disposition.filename(parsed) |> should.equal(Some("a.txt"))
}

pub fn parse_form_data_with_filename_test() {
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; name=\"upload\"; filename=\"photo.jpg\"",
    )
  content_disposition.name(parsed) |> should.equal(Some("upload"))
  content_disposition.filename(parsed) |> should.equal(Some("photo.jpg"))
}

pub fn parse_quoted_string_with_escapes_test() {
  let assert Ok(parsed) =
    content_disposition.parse("form-data; name=\"a\\\"b\\\\c\"")
  content_disposition.name(parsed) |> should.equal(Some("a\"b\\c"))
}

pub fn parse_filename_with_spaces_test() {
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; name=\"upload\"; filename=\"my file.txt\"",
    )
  content_disposition.filename(parsed) |> should.equal(Some("my file.txt"))
}

pub fn parse_filename_star_utf8_test() {
  // RFC 5987 example: filename*=UTF-8''r%C3%A9sum%C3%A9.txt
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; name=\"file\"; filename*=UTF-8''r%C3%A9sum%C3%A9.txt",
    )
  content_disposition.filename(parsed) |> should.equal(Some("résumé.txt"))
}

pub fn parse_filename_star_iso_8859_1_test() {
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; name=\"file\"; filename*=ISO-8859-1''na%EFve.txt",
    )
  content_disposition.filename(parsed) |> should.equal(Some("naïve.txt"))
}

pub fn parse_filename_star_takes_precedence_test() {
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; name=\"x\"; filename=\"plain.txt\"; filename*=UTF-8''star.txt",
    )
  content_disposition.filename(parsed) |> should.equal(Some("star.txt"))
}

pub fn parse_filename_star_unsupported_charset_rejected_test() {
  let assert Error(InvalidContentDisposition(_)) =
    content_disposition.parse(
      "form-data; name=\"x\"; filename*=BIG5''something",
    )
}

pub fn parse_filename_star_invalid_pct_rejected_test() {
  let assert Error(InvalidContentDisposition(_)) =
    content_disposition.parse("form-data; name=\"x\"; filename*=UTF-8''%ZZbad")
}

pub fn parse_unparseable_returns_error_test() {
  let assert Error(InvalidContentDisposition(value)) =
    content_disposition.parse("nope; nope")
  value |> should.equal("nope; nope")
}

pub fn parse_preserves_param_order_test() {
  let assert Ok(parsed) =
    content_disposition.parse(
      "form-data; alpha=1; beta=\"two\"; alpha=overridden",
    )
  content_disposition.params(parsed)
  |> should.equal([
    #("alpha", "1"),
    #("beta", "two"),
    #("alpha", "overridden"),
  ])
}

pub fn parse_first_occurrence_wins_for_convenience_test() {
  let assert Ok(parsed) =
    content_disposition.parse("form-data; name=\"first\"; name=\"second\"")
  content_disposition.name(parsed) |> should.equal(Some("first"))
}

pub fn parse_empty_disposition_token_rejected_test() {
  let assert Error(InvalidContentDisposition(_)) =
    content_disposition.parse(";name=x")
}

pub fn parse_tolerates_no_params_test() {
  let assert Ok(parsed) = content_disposition.parse("inline")
  content_disposition.disposition(parsed) |> should.equal("inline")
  content_disposition.name(parsed) |> should.equal(None)
  content_disposition.filename(parsed) |> should.equal(None)
  content_disposition.params(parsed) |> should.equal([])
}

pub fn parse_filename_empty_quoted_test() {
  // HTML5 unselected file input: filename=""
  let assert Ok(parsed) =
    content_disposition.parse("form-data; name=\"upload\"; filename=\"\"")
  content_disposition.filename(parsed) |> should.equal(Some(""))
}
