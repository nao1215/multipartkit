//// Cases where `parse`, `stream.parse`, the encoders or the builders did
//// not follow RFC 2046 §5.1 or RFC 7578, found by reading the RFCs section
//// by section against the code.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import multipartkit.{
  DisallowedContentType, InvalidBoundary, InvalidContentDisposition,
  InvalidContentType, InvalidHeader, InvalidHeaderName, InvalidQuotedPair,
  UnexpectedEndOfInput, UnsupportedMediaType,
}
import multipartkit/internal/scan
import multipartkit/stream

const ct = "multipart/form-data; boundary=b"

fn parse(body: BitArray) {
  multipartkit.parse(body, ct, multipartkit.default_limits)
}

fn stream_parse(body: BitArray) {
  let assert Ok(parts) =
    stream.parse(yielder.single(body), ct, multipartkit.default_limits)
  parts
  |> yielder.to_list
  |> list.try_map(fn(item) {
    case item {
      Error(error) -> Error(error)
      Ok(part) ->
        case stream.drain_body(stream.body(part)) {
          Error(error) -> Error(error)
          Ok(body) -> Ok(#(stream.headers(part), body))
        }
    }
  })
}

fn bodies(parts: List(multipartkit.Part)) -> List(BitArray) {
  list.map(parts, multipartkit.body)
}

// RFC 2046 §5.1.1: the CRLF before a delimiter belongs to the delimiter,
// so a blank line right before the delimiter ends the headers and leaves
// the body empty.

pub fn blank_line_shared_with_the_delimiter_gives_an_empty_body_test() {
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n--b--\r\n",
  >>
  let assert Ok(parts) = parse(body)
  assert bodies(parts) == [<<>>]
  assert stream_parse(body)
    == Ok([#([#("Content-Disposition", "form-data; name=\"a\"")], <<>>)])
}

pub fn part_with_no_headers_and_no_body_test() {
  let body = <<"--b\r\n\r\n--b\n\n--b--">>
  let assert Ok(parts) = parse(body)
  assert bodies(parts) == [<<>>, <<>>]
  assert stream_parse(body) == Ok([#([], <<>>), #([], <<>>)])
}

// RFC 2046 §5.1.1: close-delimiter := delimiter "--". Transport padding
// comes after the `--`, not before it.

pub fn padding_before_the_closing_dashes_is_not_a_delimiter_test() {
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx\r\n--b --\r\n",
  >>
  assert parse(body) == Error(UnexpectedEndOfInput)
  assert stream_parse(body) == Error(UnexpectedEndOfInput)
}

pub fn dash_boundary_inside_a_line_is_body_test() {
  // RFC 2046 §5.1.1: a delimiter starts a line.
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx--b\r\ny\r\n--b--",
  >>
  let assert Ok([part]) = parse(body)
  assert multipartkit.body(part) == <<"x--b\r\ny">>
  assert stream_parse(body)
    == Ok([#(multipartkit.headers(part), <<"x--b\r\ny">>)])
}

// RFC 5322 §2.2.3: a header line that starts with a space or tab
// continues the previous one. Unfolding removes the CRLF.

pub fn folded_header_is_unfolded_test() {
  let body = <<
    "--b\r\nContent-Disposition: form-data;\r\n\tname=\"a\"\r\n\r\nx\r\n--b--",
  >>
  let assert Ok([part]) = parse(body)
  assert multipartkit.name(part) == Some("a")
  assert multipartkit.headers(part)
    == [#("Content-Disposition", "form-data;\tname=\"a\"")]
  assert stream_parse(body)
    == Ok([#([#("Content-Disposition", "form-data;\tname=\"a\"")], <<"x">>)])
}

pub fn continuation_line_with_no_header_before_it_is_rejected_test() {
  let body = <<"--b\r\n x: y\r\n\r\nx\r\n--b--">>
  assert parse(body) == Error(InvalidHeader(" x: y"))
  assert stream_parse(body) == Error(InvalidHeader(" x: y"))
}

// A parsed header must not hold CR or NUL: `encode` writes it back out,
// and a receiver that ends lines at a bare CR would see a second header.

pub fn bare_cr_in_a_header_line_is_rejected_test() {
  let line = "Content-Type: text/plain\rX-Injected: 1"
  let body = <<"--b\r\n", line:utf8, "\r\n\r\nx\r\n--b--">>
  assert parse(body) == Error(InvalidHeader(line))
  assert stream_parse(body) == Error(InvalidHeader(line))
}

pub fn nul_in_a_header_line_is_rejected_test() {
  let line = "X-Note: a\u{0000}b"
  let body = <<"--b\r\n", line:utf8, "\r\n\r\nx\r\n--b--">>
  assert parse(body) == Error(InvalidHeader(line))
}

// RFC 7578 §5.1.3 lets a form send names and filenames in a charset other
// than UTF-8. Such a header is rejected, but the error names the line,
// with each byte sequence that is not UTF-8 shown as U+FFFD.

pub fn shift_jis_filename_names_the_line_test() {
  // "テスト" in Shift_JIS: 0x83 is not a UTF-8 lead byte.
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"", 0x83, 0x65,
    0x83, 0x58, 0x83, 0x67, ".txt\"\r\n\r\nx\r\n--b--",
  >>
  let line =
    "Content-Disposition: form-data; name=\"f\"; filename=\"\u{FFFD}e\u{FFFD}X\u{FFFD}g.txt\""
  assert parse(body) == Error(InvalidHeader(line))
  assert stream_parse(body) == Error(InvalidHeader(line))
}

pub fn latin1_byte_in_the_last_header_line_with_lf_names_the_line_test() {
  // "café" in Latin-1: 0xE9 starts a three-byte sequence that never comes.
  let body = <<
    "--b\nContent-Disposition: form-data; name=\"f\"\nContent-Type: text/plain; charset=caf",
    0xE9, "\n\nx\n--b--",
  >>
  let line = "Content-Type: text/plain; charset=caf\u{FFFD}"
  assert parse(body) == Error(InvalidHeader(line))
  assert stream_parse(body) == Error(InvalidHeader(line))
}

pub fn non_utf8_header_name_in_the_first_line_names_the_line_test() {
  let body = <<
    "--b\r\nX-", 0xFF,
    ": a\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx\r\n--b--",
  >>
  assert parse(body) == Error(InvalidHeader("X-\u{FFFD}: a"))
  assert stream_parse(body) == Error(InvalidHeader("X-\u{FFFD}: a"))
}

pub fn header_errors_are_reported_in_line_order_test() {
  let first_bad = <<"--b\r\nX-A: ", 0xC0, "\r\nNoColon\r\n\r\nx\r\n--b--">>
  assert parse(first_bad) == Error(InvalidHeader("X-A: \u{FFFD}"))
  assert stream_parse(first_bad) == Error(InvalidHeader("X-A: \u{FFFD}"))
  let second_bad = <<"--b\r\nNoColon\r\nX-A: ", 0xC0, "\r\n\r\nx\r\n--b--">>
  assert parse(second_bad) == Error(InvalidHeader("NoColon"))
  assert stream_parse(second_bad) == Error(InvalidHeader("NoColon"))
}

pub fn truncated_and_surrogate_sequences_are_replaced_test() {
  // A truncated "あ" (E3 81) is one U+FFFD; an encoded surrogate (ED A0 80)
  // is three, as the WHATWG decoder gives.
  let body = <<
    "--b\r\nX-A: ", 0xE3, 0x81, "|", 0xED, 0xA0, 0x80, "|", "あ":utf8,
    "\r\n\r\nx\r\n--b--",
  >>
  let line = "X-A: \u{FFFD}|\u{FFFD}\u{FFFD}\u{FFFD}|あ"
  assert parse(body) == Error(InvalidHeader(line))
  assert stream_parse(body) == Error(InvalidHeader(line))
}

pub fn sequences_at_the_edges_of_the_utf8_ranges_are_kept_test() {
  // The first and last lead byte of each range, and the lowest and highest
  // continuation byte, in a line that is not UTF-8 because of 0xFF.
  let body = <<
    "--b\r\nX-A: ", 0xFF, "|", 0xC2, 0x80, "|", 0xDF, 0xBF, "|", 0xE1, 0x80,
    0x80, "|", 0xEF, 0x80, 0x80, "|", 0xF1, 0x80, 0x80, 0x80, "|", 0xF3, 0x80,
    0x80, 0x80, "\r\n\r\nx\r\n--b--",
  >>
  let line =
    "X-A: \u{FFFD}|\u{0080}|\u{07FF}|\u{1000}|\u{F000}|\u{40000}|\u{C0000}"
  assert parse(body) == Error(InvalidHeader(line))
  assert stream_parse(body) == Error(InvalidHeader(line))
}

pub fn non_utf8_folded_line_names_the_physical_line_test() {
  let body = <<
    "--b\r\nContent-Disposition: form-data;\r\n\tfilename=\"", 0xE9,
    "\"\r\n\r\nx\r\n--b--",
  >>
  assert parse(body) == Error(InvalidHeader("\tfilename=\"\u{FFFD}\""))
  assert stream_parse(body) == Error(InvalidHeader("\tfilename=\"\u{FFFD}\""))
}

pub fn non_utf8_header_split_across_chunks_names_the_line_test() {
  let chunks = [
    <<"--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"", 0xE3>>,
    <<0x81, "\"\r\n\r\nx\r\n--b--">>,
  ]
  let assert Ok(parts) =
    stream.parse(yielder.from_list(chunks), ct, multipartkit.default_limits)
  assert yielder.to_list(parts)
    == [
      Error(InvalidHeader(
        "Content-Disposition: form-data; name=\"f\"; filename=\"\u{FFFD}\"",
      )),
    ]
}

// RFC 5322 §3.6.8: a field name is printable ASCII other than `:`, so
// `Content-Disposition : ...` is not a Content-Disposition header.

pub fn space_before_the_colon_is_rejected_test() {
  let line = "Content-Disposition : form-data; name=\"admin\""
  let body = <<"--b\r\n", line:utf8, "\r\n\r\nx\r\n--b--">>
  assert parse(body) == Error(InvalidHeader(line))
}

pub fn new_part_rejects_a_header_name_that_parse_would_reject_test() {
  assert multipartkit.new_part(headers: [#("X Note", "a")], body: <<>>)
    == Error(InvalidHeaderName("X Note"))
  assert multipartkit.new_part(headers: [#("Café", "a")], body: <<>>)
    == Error(InvalidHeaderName("Café"))
}

// RFC 6266 §4.1: a Content-Disposition with the same parameter twice is
// invalid. Parameter names ignore case.

pub fn duplicate_disposition_parameter_is_rejected_test() {
  let value = "form-data; name=\"a\"; NAME=\"admin\""
  assert multipartkit.parse_content_disposition(value)
    == Error(InvalidContentDisposition(value))
  let body = <<
    "--b\r\nContent-Disposition: ",
    value:utf8,
    "\r\n\r\nx\r\n--b--",
  >>
  assert parse(body) == Error(InvalidContentDisposition(value))
}

pub fn filename_and_filename_star_are_not_duplicates_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "attachment; filename=\"a.txt\"; filename*=UTF-8''%C3%A9.txt",
    )
  assert parsed.filename == Some("é.txt")
}

// RFC 6266 §4.1 (implied LWS of RFC 2616): whitespace may surround `=`.

pub fn whitespace_around_the_equals_sign_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("form-data; name = \"a\"")
  assert parsed.name == Some("a")
}

// RFC 5987 §3.2.1: value-chars := *( pct-encoded / attr-char ).

// RFC 6266 §4.3: a recipient that cannot decode `filename*` uses
// `filename`. The whole body must not fail because of it.

pub fn ext_value_with_characters_outside_attr_char_is_ignored_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "attachment; filename=\"a b.txt\"; filename*=\"UTF-8''a b.txt\"",
    )
  assert parsed.filename == Some("a b.txt")
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "attachment; filename*=UTF-8''a'b.txt",
    )
  assert parsed.filename == None
  let body = <<
    "--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a b\"; filename*=\"UTF-8''a b\"\r\n\r\nx\r\n--b--",
  >>
  let assert Ok([part]) = parse(body)
  assert multipartkit.filename(part) == Some("a b")
}

// RFC 6838 §4.3: a parameter given twice is an error. Two `boundary`
// parameters would let two parsers split the body differently.

pub fn duplicate_boundary_parameter_is_rejected_test() {
  let content_type = "multipart/form-data; boundary=a; Boundary=b"
  assert multipartkit.parse(<<>>, content_type, multipartkit.default_limits)
    == Error(InvalidContentType(content_type))
  let assert Error(InvalidContentType(_)) =
    stream.parse(yielder.empty(), content_type, multipartkit.default_limits)
}

// RFC 9110 §5.6.6: parameters := *( OWS ";" OWS [ parameter ] ), so an
// empty parameter is allowed.

// RFC 9110 §5.6.6: no whitespace around `=` in a media type parameter, so
// `boundary = b` is not read the way a strict parser in front would not.

pub fn whitespace_around_equals_in_content_type_is_rejected_test() {
  let content_type = "multipart/form-data; boundary = b"
  assert multipartkit.parse(
      <<"--b--">>,
      content_type,
      multipartkit.default_limits,
    )
    == Error(InvalidContentType(content_type))
}

// A Content-Disposition with thousands of parameters is checked for
// repeats in linear time.

pub fn many_disposition_parameters_are_checked_quickly_test() {
  let parameters =
    list.repeat(Nil, 3001)
    |> list.index_map(fn(_, i) { "; k" <> int.to_string(i) <> "=v" })
    |> string.concat
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition("form-data" <> parameters)
  assert list.length(parsed.parameters) == 3001
  let assert Error(InvalidContentDisposition(_)) =
    multipartkit.parse_content_disposition(
      "form-data" <> parameters <> "; K3000=w",
    )
}

pub fn empty_content_type_parameters_are_allowed_test() {
  let content_type = "multipart/form-data;; boundary=b;"
  assert multipartkit.parse(
      <<"--b--">>,
      content_type,
      multipartkit.default_limits,
    )
    == Ok([])
}

// RFC 7578 §4.2: the RFC 5987 `filename*` parameter MUST NOT be used. A
// filename outside ASCII goes in the quoted `filename` as UTF-8.

pub fn new_file_writes_a_utf8_filename_without_filename_star_test() {
  let assert Ok(part) =
    multipartkit.new_file(
      name: "file",
      filename: "写真 \"1\".png",
      content_type: "image/png",
      body: <<>>,
    )
  assert multipartkit.header(part, "content-disposition")
    == Ok("form-data; name=\"file\"; filename=\"写真 \\\"1\\\".png\"")
  assert multipartkit.filename(part) == Some("写真 \"1\".png")
  let #(content_type, body) = multipartkit.encode_form([part])
  let assert Ok(text) = bit_array.to_string(body)
  assert !string.contains(text, "filename*")
  let assert Ok([parsed]) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  assert parsed == part
}

// RFC 2046 §5.1.1 and RFC 7578 §4.1: lines in a body part must not start
// with the dash-boundary, or the receiver splits the part there.

fn file_part(body: BitArray) -> multipartkit.Part {
  let assert Ok(part) =
    multipartkit.new_file(
      name: "f",
      filename: "f.bin",
      content_type: "application/octet-stream",
      body:,
    )
  part
}

pub fn encode_rejects_a_body_line_that_starts_with_the_boundary_test() {
  assert multipartkit.encode([file_part(<<"x\r\n--b--\r\ny">>)], "b")
    == Error(InvalidBoundary("b"))
  assert multipartkit.encode([file_part(<<"--bc">>)], "b")
    == Error(InvalidBoundary("b"))
  assert multipartkit.encode([file_part(<<"x\n--b">>)], "b")
    == Error(InvalidBoundary("b"))
  let assert Ok(_) = multipartkit.encode([file_part(<<"x--b\r\n-b">>)], "b")
}

pub fn encode_rejects_a_header_line_that_starts_with_the_boundary_test() {
  let assert Ok(part) =
    multipartkit.new_part(headers: [#("--b--", "x")], body: <<>>)
  assert multipartkit.encode([part], "b") == Error(InvalidBoundary("b"))
}

fn padding(size: Int) -> BitArray {
  bit_array.from_string(string.repeat("a", size))
}

fn stream_encode_last(body: BitArray) {
  stream.encode(yielder.single(stream.from_part(file_part(body))), "b")
  |> yielder.to_list
  |> list.last
}

pub fn stream_encode_rejects_the_boundary_across_chunks_test() {
  // `stream.from_part` cuts a body into 64 KiB chunks. Put `\n-` at the
  // end of the first chunk and `-b` at the start of the second.
  let body = <<padding(65_534):bits, "\n--b\r\n":utf8>>
  assert stream_encode_last(body) == Ok(Error(InvalidBoundary("b")))
  let body = <<padding(65_535):bits, "\n--b":utf8>>
  assert stream_encode_last(body) == Ok(Error(InvalidBoundary("b")))
  let body = <<padding(65_534):bits, "x--b\r\n":utf8>>
  assert stream_encode_last(body) == Ok(Ok(<<"--b--\r\n">>))
}

pub fn stream_encode_carries_only_a_line_that_can_still_become_the_boundary_test() {
  // The first chunk ends with a line `--` that starts right after the
  // lowest offset a line of the boundary's length can start at.
  let body = <<padding(65_533):bits, "\n--b":utf8>>
  assert stream_encode_last(body) == Ok(Error(InvalidBoundary("b")))
  // The second chunk starts in the middle of a line.
  let body = <<padding(65_536):bits, "--b\r\n":utf8>>
  assert stream_encode_last(body) == Ok(Ok(<<"--b--\r\n">>))
  // The same for chunks shorter than the boundary, as stream.parse gives.
  let pattern = <<"--b">>
  assert scan.check_line_starts(Some(<<>>), <<"\n--">>, pattern)
    == Ok(Some(<<"--">>))
  assert scan.check_line_starts(Some(<<>>), <<"a\n--">>, pattern)
    == Ok(Some(<<"--">>))
  assert scan.check_line_starts(None, <<"--b">>, pattern) == Ok(None)
  assert scan.check_line_starts(None, <<"-">>, pattern) == Ok(None)
  assert scan.check_line_starts(Some(<<>>), <<"-">>, pattern)
    == Ok(Some(<<"-">>))
}

// Error variants that hold a `String` have labels, like the others.

pub fn error_variants_have_labels_test() {
  let assert Error(InvalidContentType(content_type: "x")) =
    multipartkit.parse(<<>>, "x", multipartkit.default_limits)
  let assert Error(UnsupportedMediaType(media_type: "text/plain")) =
    multipartkit.parse(<<>>, "text/plain", multipartkit.default_limits)
  let assert Error(InvalidBoundary(boundary: "")) = multipartkit.encode([], "")
  let assert Error(InvalidHeader(line: "x")) =
    parse(<<"--b\r\nx\r\n\r\n--b--">>)
  let assert Error(InvalidContentDisposition(value: ";")) =
    multipartkit.parse_content_disposition(";")
  let assert Error(InvalidQuotedPair(value: _)) =
    multipartkit.parse_content_disposition("a; name=\"\\\u{0001}\"")
  let assert Error(DisallowedContentType(
    content_type: "application/octet-stream",
  )) = multipartkit.allowed_content_types(file_part(<<>>), [])
}

// Found by the raw-message property in stream_differential_test: the
// result depended on how the input was split, and `parse` disagreed with
// `stream.parse`. Both now read up to max_body_bytes and report the first
// problem in byte order.

fn small_limits(body: Int, part: Int, header: Int) -> multipartkit.Limits {
  multipartkit.Limits(
    max_body_bytes: body,
    max_part_bytes: part,
    max_parts: 10,
    max_header_bytes: header,
  )
}

fn stream_with(chunks: List(BitArray), limits: multipartkit.Limits) {
  let assert Ok(parts) = stream.parse(yielder.from_list(chunks), ct, limits)
  parts
  |> yielder.to_list
  |> list.map(fn(item) { item |> result_names })
}

fn result_names(
  item: Result(stream.StreamPart, multipartkit.MultipartError),
) -> Result(option.Option(String), multipartkit.MultipartError) {
  case item {
    Ok(part) -> Ok(stream.name(part))
    Error(error) -> Error(error)
  }
}

pub fn an_error_before_the_body_limit_wins_over_body_too_large_test() {
  let body = <<"preamble\r\n--b \r\n\n--\r\n--b-- \r\nepilogue">>
  let limits = small_limits(17, 0, 0)
  assert multipartkit.parse(body, ct, limits)
    == Error(multipartkit.HeaderTooLarge(0))
  assert stream_with([body], limits) == [Error(multipartkit.HeaderTooLarge(0))]
  let bytes =
    list.map(string.to_graphemes(bit_array_text(body)), fn(c) { <<c:utf8>> })
  assert stream_with(bytes, limits) == [Error(multipartkit.HeaderTooLarge(0))]
}

pub fn an_unfinished_part_over_the_part_limit_is_part_too_large_test() {
  let body = <<"--b\r\n\r\n0123456789">>
  let limits = small_limits(1000, 4, 100)
  assert multipartkit.parse(body, ct, limits)
    == Error(multipartkit.PartTooLarge(4))
  assert stream_with([body], limits) == [Error(multipartkit.PartTooLarge(4))]
}

pub fn unfinished_input_exactly_at_a_limit_is_unexpected_end_test() {
  // Six header bytes after the delimiter, and no blank line yet.
  let headers = <<"--b\r\nX-A: 1">>
  assert multipartkit.parse(headers, ct, small_limits(1000, 100, 6))
    == Error(UnexpectedEndOfInput)
  assert stream_with([headers], small_limits(1000, 100, 6))
    == [Error(UnexpectedEndOfInput)]
  assert multipartkit.parse(headers, ct, small_limits(1000, 100, 5))
    == Error(multipartkit.HeaderTooLarge(5))
  assert stream_with([headers], small_limits(1000, 100, 5))
    == [Error(multipartkit.HeaderTooLarge(5))]
  // Ten body bytes, of which the last four could still start `\r\n--b`.
  let body = <<"--b\r\n\r\n0123456789">>
  assert multipartkit.parse(body, ct, small_limits(1000, 6, 100))
    == Error(UnexpectedEndOfInput)
  assert stream_with([body], small_limits(1000, 6, 100))
    == [Error(UnexpectedEndOfInput)]
  assert multipartkit.parse(body, ct, small_limits(1000, 5, 100))
    == Error(multipartkit.PartTooLarge(5))
}

pub fn transport_padding_does_not_count_as_part_body_test() {
  // `x` is the whole body: the spaces are padding after the delimiter.
  let body = <<"--b\r\n\r\nx\r\n--b", "          ", "\r\n\r\n--b--">>
  let limits = small_limits(1000, 1, 100)
  let assert Ok([first, _]) = multipartkit.parse(body, ct, limits)
  assert multipartkit.body(first) == <<"x">>
  let chunks = [<<"--b\r\n\r\nx\r\n--b     ">>, <<"     \r\n\r\n--b--">>]
  assert stream_with(chunks, limits) == [Ok(option.None), Ok(option.None)]
}

fn bit_array_text(body: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(body)
  text
}

// Recursion through `use` is not a tail call, so these overflowed the
// stack on JavaScript.

pub fn long_trailing_whitespace_is_trimmed_test() {
  let assert Ok(part) =
    multipartkit.new_part(
      headers: [#("X-Note", "a" <> string.repeat(" ", 20_000))],
      body: <<>>,
    )
  assert multipartkit.header(part, "x-note") == Ok("a")
}

pub fn long_extended_value_is_decoded_test() {
  let assert Ok(parsed) =
    multipartkit.parse_content_disposition(
      "attachment; filename*=UTF-8''" <> string.repeat("%41", 10_000),
    )
  assert parsed.filename == Some(string.repeat("A", 10_000))
}
