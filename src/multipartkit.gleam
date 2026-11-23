//// Parse, query and build multipart bodies such as `multipart/form-data`
//// uploads, on Erlang and JavaScript.
////
//// For bodies too large to hold in memory, see `multipartkit/stream`.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimetype
import multipartkit/internal/bytes
import multipartkit/internal/disposition
import multipartkit/internal/headers as header_block
import multipartkit/internal/scan
import multipartkit/internal/text.{QuotedPairInvalid, QuotedSyntax}

// Types -----------------------------------------------------------------------

/// Why a multipart body could not be parsed, built or queried.
///
/// Variants that hold a `String` hold the offending input.
pub type MultipartError {
  /// The Content-Type has no `boundary` parameter.
  MissingBoundary
  /// The Content-Type is not a media type with parameters.
  InvalidContentType(String)
  /// The boundary is empty, longer than 70 characters, ends in a space or
  /// contains a character RFC 2046 does not allow.
  InvalidBoundary(String)
  /// The media type is not `multipart/*`.
  UnsupportedMediaType(String)
  /// A header line is folded, has no `:` or has an empty name. It holds the
  /// line, or `""` when the header block is not UTF-8.
  InvalidHeader(String)
  /// A `Content-Disposition` value could not be parsed. It holds the value.
  InvalidContentDisposition(String)
  /// A `Content-Disposition` quoted string escapes a control character, as in
  /// `\` followed by NUL. It holds the value.
  InvalidQuotedPair(String)
  /// The body ended before the closing boundary.
  UnexpectedEndOfInput
  /// The body is larger than `Limits.max_body_bytes`.
  BodyTooLarge(limit: Int)
  /// A part body is larger than `Limits.max_part_bytes`.
  PartTooLarge(limit: Int)
  /// The body has more parts than `Limits.max_parts`.
  TooManyParts(limit: Int)
  /// A part's header block is larger than `Limits.max_header_bytes`.
  HeaderTooLarge(limit: Int)
  /// A header name given to `new_part` is empty or contains CR, LF, NUL or
  /// `:`.
  InvalidHeaderName(name: String)
  /// A header value given to `new_part`, or a name, filename or content type
  /// given to `new_field` or `new_file`, contains CR, LF or NUL.
  InvalidHeaderValue(name: String, value: String)
  /// The field name given to `new_field` or `new_file` is empty or only
  /// whitespace.
  EmptyFieldName(name: String)
  /// `field` found no text field with this name.
  MissingField(name: String)
  /// `field` found the text field, but its body is not UTF-8.
  InvalidUtf8Field(name: String)
  /// `file` found no file part with this name.
  MissingFile(name: String)
  /// `allowed_content_types` rejected the part's Content-Type. It holds the
  /// Content-Type, or `""` when the part has none.
  DisallowedContentType(String)
}

/// One part of a multipart body: its headers and its body bytes.
///
/// Get one from `parse`, `new_field`, `new_file` or `new_part`. The `name`,
/// `filename` and `content_type` functions read values taken from the
/// headers.
pub opaque type Part {
  // `name`, `filename` and `content_type` are always derived from `headers`
  // by `from_headers`, and no header contains CR, LF or NUL.
  Part(
    headers: List(#(String, String)),
    name: Option(String),
    filename: Option(String),
    content_type: Option(String),
    body: BitArray,
  )
}

/// Upper bounds that `parse` and `stream.parse` enforce while reading.
///
/// A value equal to a limit is allowed. Start from `default_limits` and
/// change the fields you need:
///
/// ```gleam
/// multipartkit.Limits(..multipartkit.default_limits, max_parts: 10)
/// ```
pub type Limits {
  Limits(
    /// Bytes in the whole body, including the preamble and epilogue.
    max_body_bytes: Int,
    /// Bytes in one part body.
    max_part_bytes: Int,
    /// Number of parts.
    max_parts: Int,
    /// Bytes in one part's header block.
    max_header_bytes: Int,
  )
}

/// 10 MB body, 5 MB per part, 100 parts and 16 KiB of headers per part.
pub const default_limits =
  Limits(
    max_body_bytes: 10_000_000,
    max_part_bytes: 5_000_000,
    max_parts: 100,
    max_header_bytes: 16_384,
  )

/// A parsed `Content-Disposition` header value.
pub type ContentDisposition {
  ContentDisposition(
    /// The disposition type in lowercase, such as `"form-data"` or
    /// `"attachment"`.
    disposition: String,
    /// The `name` parameter.
    name: Option(String),
    /// The `filename*` parameter decoded from RFC 5987 form when present,
    /// otherwise the `filename` parameter.
    filename: Option(String),
    /// Every parameter in input order, with quoted strings unquoted and
    /// `*` forms not decoded.
    parameters: List(#(String, String)),
  )
}

// Building parts --------------------------------------------------------------

/// Creates a text field part for a `multipart/form-data` body.
///
/// Returns `Error(EmptyFieldName(name))` when the name is empty or only
/// whitespace, and `Error(InvalidHeaderValue(..))` when it contains CR, LF or
/// NUL.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(title) = new_field(name: "title", value: "hello")
/// name(title)
/// // -> Some("title")
/// ```
///
/// ```gleam
/// new_field(name: "", value: "hello")
/// // -> Error(EmptyFieldName(""))
/// ```
///
pub fn new_field(
  name name: String,
  value value: String,
) -> Result(Part, MultipartError) {
  new_form_data_part(name, None, [], <<value:utf8>>)
}

/// Creates a file part for a `multipart/form-data` body.
///
/// A filename that is not printable ASCII is also written in RFC 5987
/// `filename*` form, so it survives the round trip through `parse`. The
/// errors are the same as `new_field`, and the filename and content type are
/// checked for CR, LF and NUL too. `infer_content_type` can pick the content
/// type.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(avatar) =
///   new_file(
///     name: "avatar",
///     filename: "cat.png",
///     content_type: "image/png",
///     body: png_bytes,
///   )
/// filename(avatar)
/// // -> Some("cat.png")
/// ```
///
pub fn new_file(
  name name: String,
  filename filename: String,
  content_type content_type: String,
  body body: BitArray,
) -> Result(Part, MultipartError) {
  new_form_data_part(
    name,
    Some(filename),
    [#("Content-Type", content_type)],
    body,
  )
}

fn new_form_data_part(
  name: String,
  filename: Option(String),
  other_headers: List(#(String, String)),
  body: BitArray,
) -> Result(Part, MultipartError) {
  use <- bool.guard(
    when: string.trim(name) == "",
    return: Error(EmptyFieldName(name)),
  )
  // A filename that is not ASCII goes out percent-encoded, so new_part would
  // not see a CR, LF or NUL in it. Check both values here.
  use _ <- result.try(
    list.try_each([name, ..option.values([filename])], fn(value) {
      case disposition.has_header_breaking_bytes(value) {
        True -> Error(InvalidHeaderValue("Content-Disposition", value))
        False -> Ok(Nil)
      }
    }),
  )
  let content_disposition = disposition.build_form_data_value(name, filename)
  new_part(
    headers: [#("Content-Disposition", content_disposition), ..other_headers],
    body:,
  )
}

/// Creates a part from raw headers, for bodies such as `multipart/mixed`.
///
/// Header values lose leading and trailing spaces and tabs, as `parse` does.
/// `name`, `filename` and `content_type` are read from the headers in the
/// same way as for a parsed part.
///
/// Returns `Error(InvalidHeaderName(name))` for an empty header name or one
/// with CR, LF, NUL or `:`, `Error(InvalidHeaderValue(name, value))` for a
/// value with CR, LF or NUL, and `Error(InvalidContentDisposition(value))`
/// when the `Content-Disposition` header cannot be parsed.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(part) =
///   new_part(headers: [#("Content-Type", "text/plain")], body: <<"hi">>)
/// content_type(part)
/// // -> Some("text/plain")
/// ```
///
/// ```gleam
/// new_part(headers: [#("X-Note", "a\r\nb")], body: <<>>)
/// // -> Error(InvalidHeaderValue("X-Note", "a\r\nb"))
/// ```
///
pub fn new_part(
  headers headers: List(#(String, String)),
  body body: BitArray,
) -> Result(Part, MultipartError) {
  use headers <- result.try(list.try_map(headers, check_header))
  from_headers(headers, body)
}

fn check_header(
  header: #(String, String),
) -> Result(#(String, String), MultipartError) {
  let #(name, value) = header
  use <- bool.guard(
    when: name == ""
      || string.contains(name, ":")
      || disposition.has_header_breaking_bytes(name),
    return: Error(InvalidHeaderName(name)),
  )
  use <- bool.guard(
    when: disposition.has_header_breaking_bytes(value),
    return: Error(InvalidHeaderValue(name, value)),
  )
  Ok(#(name, header_block.trim_ows(value)))
}

fn from_headers(
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Part, MultipartError) {
  let content_type = option.from_result(text.find_ci(headers, "content-type"))
  case text.find_ci(headers, "content-disposition") {
    Error(Nil) ->
      Ok(Part(headers:, name: None, filename: None, content_type:, body:))
    Ok(value) -> {
      use parsed <- result.try(
        parse_content_disposition(value)
        |> result.replace_error(InvalidContentDisposition(value)),
      )
      // Only form-data parts have a field name. An `attachment` part keeps
      // its headers, but `field` and `file` do not see it.
      case parsed.disposition {
        "form-data" ->
          Ok(Part(
            headers:,
            name: parsed.name,
            filename: parsed.filename,
            content_type:,
            body:,
          ))
        _ ->
          Ok(Part(headers:, name: None, filename: None, content_type:, body:))
      }
    }
  }
}

/// Guesses a content type from the filename's extension, then from the
/// body's leading bytes, using `nao1215/mimetype`. Returns
/// `"application/octet-stream"` when neither is recognised.
///
/// Plain printable text with no known extension is `"text/plain"`.
///
/// ## Examples
///
/// ```gleam
/// infer_content_type("photo.png", <<>>)
/// // -> "image/png"
/// ```
///
/// ```gleam
/// infer_content_type("blob", <<0x89, "PNG":utf8, 0x0D, 0x0A, 0x1A, 0x0A>>)
/// // -> "image/png"
/// ```
///
/// ```gleam
/// infer_content_type("blob", <<0, 1, 2>>)
/// // -> "application/octet-stream"
/// ```
///
pub fn infer_content_type(filename: String, body: BitArray) -> String {
  mimetype.filename_to_mime_type(filename)
  |> result.lazy_or(fn() { mimetype.detect(body) })
  |> result.map(mimetype.essence)
  |> result.unwrap("application/octet-stream")
}

// Reading parts ---------------------------------------------------------------

/// Returns every header of the part in the order it was written, with the
/// names as written.
///
pub fn headers(part: Part) -> List(#(String, String)) {
  part.headers
}

/// Returns the value of the first header whose name matches, ignoring ASCII
/// case.
///
/// ## Examples
///
/// ```gleam
/// header(part, "content-type")
/// // -> Ok("image/png")
/// ```
///
/// ```gleam
/// header(part, "x-missing")
/// // -> Error(Nil)
/// ```
///
pub fn header(part: Part, name: String) -> Result(String, Nil) {
  text.find_ci(part.headers, name)
}

/// Returns the `name` parameter of a `form-data` part's
/// `Content-Disposition`. Other parts have no name.
///
pub fn name(part: Part) -> Option(String) {
  part.name
}

/// Returns the filename of a `form-data` part, preferring the RFC 5987
/// `filename*` parameter.
///
/// The filename is exactly what the client sent and may contain `../` or an
/// absolute path. Do not join it onto a server path unchecked.
///
pub fn filename(part: Part) -> Option(String) {
  part.filename
}

/// Returns the value of the part's `Content-Type` header.
///
pub fn content_type(part: Part) -> Option(String) {
  part.content_type
}

/// Returns the part's body bytes.
///
pub fn body(part: Part) -> BitArray {
  part.body
}

// Parsing ---------------------------------------------------------------------

/// Parses a whole multipart body.
///
/// `content_type` is the HTTP `Content-Type` value with its `boundary`
/// parameter. The preamble before the first boundary and the epilogue after
/// the last one are ignored. Lines may end in CRLF or LF.
///
/// The Content-Type is checked first: `InvalidContentType`, then
/// `UnsupportedMediaType`, `MissingBoundary` and `InvalidBoundary`. Then the
/// body may fail with `UnexpectedEndOfInput`, `InvalidHeader`,
/// `InvalidContentDisposition`, `InvalidQuotedPair` or one of the limit
/// errors.
///
/// ## Examples
///
/// ```gleam
/// let body = <<
///   "--b\r\n",
///   "Content-Disposition: form-data; name=\"title\"\r\n\r\n",
///   "hello\r\n",
///   "--b--\r\n",
/// >>
/// let assert Ok(parts) =
///   parse(body, "multipart/form-data; boundary=b", default_limits)
/// field(parts, "title")
/// // -> Ok("hello")
/// ```
///
/// ```gleam
/// parse(<<>>, "application/json", default_limits)
/// // -> Error(UnsupportedMediaType("application/json"))
/// ```
///
pub fn parse(
  body: BitArray,
  content_type: String,
  limits: Limits,
) -> Result(List(Part), MultipartError) {
  use boundary <- result.try(boundary(content_type))
  use <- bool.guard(
    when: bit_array.byte_size(body) > limits.max_body_bytes,
    return: Error(BodyTooLarge(limits.max_body_bytes)),
  )
  let pattern = scan.dash_pattern(boundary)
  case scan.find_delimiter(body, pattern, 0) {
    scan.Incomplete -> Error(UnexpectedEndOfInput)
    // The first delimiter is the closing one: a body with no parts.
    scan.Found(_, scan.Closing, _) -> Ok([])
    scan.Found(_, scan.Delimiter, after) ->
      parse_loop(body, pattern, after, limits, [], 0)
  }
}

fn parse_loop(
  body: BitArray,
  pattern: BitArray,
  cursor: Int,
  limits: Limits,
  parts: List(Part),
  count: Int,
) -> Result(List(Part), MultipartError) {
  use #(blank_at, body_start) <- result.try(
    bytes.find_blank_line(body, cursor)
    |> result.replace_error(UnexpectedEndOfInput),
  )
  use <- bool.guard(
    when: body_start - cursor > limits.max_header_bytes,
    return: Error(HeaderTooLarge(limits.max_header_bytes)),
  )
  use head <- result.try(
    parse_part_headers(bytes.slice_or_empty(body, cursor, blank_at - cursor)),
  )
  case scan.find_delimiter(body, pattern, body_start) {
    scan.Incomplete -> Error(UnexpectedEndOfInput)
    scan.Found(body_end, kind, after) -> {
      let size = body_end - body_start
      use <- bool.guard(
        when: size > limits.max_part_bytes,
        return: Error(PartTooLarge(limits.max_part_bytes)),
      )
      use <- bool.guard(
        when: count + 1 > limits.max_parts,
        return: Error(TooManyParts(limits.max_parts)),
      )
      let part =
        Part(..head, body: bytes.slice_or_empty(body, body_start, size))
      case kind {
        scan.Closing -> Ok(list.reverse([part, ..parts]))
        scan.Delimiter ->
          parse_loop(body, pattern, after, limits, [part, ..parts], count + 1)
      }
    }
  }
}

/// Reads the boundary from a Content-Type value. Shared with
/// `multipartkit/stream`.
@internal
pub fn boundary(content_type: String) -> Result(String, MultipartError) {
  let invalid = InvalidContentType(content_type)
  use #(media_type, parameters) <- result.try(
    parse_media_type(text.skip_ows(content_type))
    |> result.replace_error(invalid),
  )
  use <- bool.guard(
    when: !is_multipart(media_type),
    return: Error(UnsupportedMediaType(media_type)),
  )
  use found <- result.try(
    parse_parameters(parameters, [], text.read_token_or_quoted)
    |> result.replace_error(invalid),
  )
  case text.find_ci(found, "boundary") {
    Error(Nil) -> Error(MissingBoundary)
    Ok(value) ->
      case text.is_valid_boundary(value) {
        True -> Ok(value)
        False -> Error(InvalidBoundary(value))
      }
  }
}

fn parse_media_type(input: String) -> Result(#(String, String), Nil) {
  case text.read_token(input) {
    #("", _) -> Error(Nil)
    #(type_, rest) ->
      case string.pop_grapheme(rest) {
        Ok(#("/", rest)) ->
          case text.read_token(rest) {
            #("", _) -> Error(Nil)
            #(subtype, tail) -> Ok(#(type_ <> "/" <> subtype, tail))
          }
        _ -> Error(Nil)
      }
  }
}

fn is_multipart(media_type: String) -> Bool {
  let lower = text.ascii_lowercase(media_type)
  string.starts_with(lower, "multipart/") && lower != "multipart/"
}

type ParameterError(value_error) {
  MalformedParameter
  MalformedValue(value_error)
}

/// Reads `; key=value` parameters until the end of the input, using
/// `read_value` for each value.
fn parse_parameters(
  input: String,
  parameters: List(#(String, String)),
  read_value: fn(String) -> Result(#(String, String), value_error),
) -> Result(List(#(String, String)), ParameterError(value_error)) {
  case text.skip_ows(input) {
    "" -> Ok(list.reverse(parameters))
    ";" <> rest -> {
      use #(parameter, rest) <- result.try(parse_parameter(rest, read_value))
      parse_parameters(rest, [parameter, ..parameters], read_value)
    }
    _ -> Error(MalformedParameter)
  }
}

fn parse_parameter(
  input: String,
  read_value: fn(String) -> Result(#(String, String), value_error),
) -> Result(#(#(String, String), String), ParameterError(value_error)) {
  case text.read_token(text.skip_ows(input)) {
    #("", _) -> Error(MalformedParameter)
    #(key, "=" <> rest) -> {
      use #(value, rest) <- result.try(
        read_value(rest) |> result.map_error(MalformedValue),
      )
      Ok(#(#(key, value), rest))
    }
    _ -> Error(MalformedParameter)
  }
}

/// Parses one part's header block into a part with an empty body. Shared with
/// `multipartkit/stream`.
@internal
pub fn parse_part_headers(block: BitArray) -> Result(Part, MultipartError) {
  use headers <- result.try(
    header_block.parse_block(block)
    |> result.map_error(fn(invalid) { InvalidHeader(invalid.line) }),
  )
  from_headers(headers, <<>>)
}

/// Parses a `Content-Disposition` header value.
///
/// `parse` already reads the field name and filename of each part, so this is
/// for other uses, such as the `attachment` parts of a `multipart/mixed`
/// body.
///
/// Returns `Error(InvalidQuotedPair(value))` when a quoted string escapes a
/// control character, and `Error(InvalidContentDisposition(value))` for any
/// other malformed value, including a `filename*` that is not valid UTF-8 or
/// ISO-8859-1.
///
/// ## Examples
///
/// ```gleam
/// parse_content_disposition("attachment; filename=\"a.txt\"")
/// // -> Ok(ContentDisposition(
/// //   disposition: "attachment",
/// //   name: None,
/// //   filename: Some("a.txt"),
/// //   parameters: [#("filename", "a.txt")],
/// // ))
/// ```
///
/// ```gleam
/// parse_content_disposition("; name=x")
/// // -> Error(InvalidContentDisposition("; name=x"))
/// ```
///
pub fn parse_content_disposition(
  value: String,
) -> Result(ContentDisposition, MultipartError) {
  let invalid = InvalidContentDisposition(value)
  case text.read_token(text.skip_ows(value)) {
    #("", _) -> Error(invalid)
    #(token, rest) -> {
      use parameters <- result.try(
        parse_parameters(rest, [], text.read_token_or_quoted_strict)
        |> result.map_error(fn(error) {
          case error {
            MalformedValue(QuotedPairInvalid) -> InvalidQuotedPair(value)
            MalformedValue(QuotedSyntax) | MalformedParameter -> invalid
          }
        }),
      )
      use name <- result.try(pick_parameter(parameters, "name", invalid))
      use filename <- result.try(pick_parameter(parameters, "filename", invalid))
      Ok(ContentDisposition(
        disposition: text.ascii_lowercase(token),
        name:,
        filename:,
        parameters:,
      ))
    }
  }
}

/// Returns the decoded `key*` parameter if present, otherwise the plain `key`
/// parameter.
fn pick_parameter(
  parameters: List(#(String, String)),
  key: String,
  invalid: MultipartError,
) -> Result(Option(String), MultipartError) {
  case text.find_ci(parameters, key <> "*") {
    Ok(raw) ->
      disposition.decode_extended_value(raw)
      |> result.map(Some)
      |> result.replace_error(invalid)
    Error(Nil) -> Ok(option.from_result(text.find_ci(parameters, key)))
  }
}

// Querying parts --------------------------------------------------------------

/// Returns the first text field with this name, decoded as UTF-8. A text
/// field is a `form-data` part with a name and no filename.
///
/// Returns `Error(MissingField(name))` when there is none, and
/// `Error(InvalidUtf8Field(name))` when its body is not UTF-8.
///
/// ## Examples
///
/// ```gleam
/// field(parts, "title")
/// // -> Ok("hello")
/// ```
///
/// ```gleam
/// field(parts, "missing")
/// // -> Error(MissingField("missing"))
/// ```
///
pub fn field(
  parts: List(Part),
  name: String,
) -> Result(String, MultipartError) {
  case list.find(parts, is_text_field(_, name)) {
    Error(Nil) -> Error(MissingField(name))
    Ok(part) ->
      bit_array.to_string(part.body)
      |> result.replace_error(InvalidUtf8Field(name))
  }
}

/// Returns every text field with this name in input order, skipping bodies
/// that are not UTF-8.
///
pub fn fields(parts: List(Part), name: String) -> List(String) {
  list.filter_map(parts, fn(part) {
    case is_text_field(part, name) {
      True -> bit_array.to_string(part.body)
      False -> Error(Nil)
    }
  })
}

/// Returns the first file part with this name. A file part is a `form-data`
/// part with a filename, even an empty one, which is what browsers send for a
/// file input left empty.
///
/// Returns `Error(MissingFile(name))` when there is none.
///
pub fn file(parts: List(Part), name: String) -> Result(Part, MultipartError) {
  list.find(parts, is_file(_, name))
  |> result.replace_error(MissingFile(name))
}

/// Returns every file part with this name in input order.
///
pub fn files(parts: List(Part), name: String) -> List(Part) {
  list.filter(parts, is_file(_, name))
}

/// Returns the field names in the order they first appear, without
/// duplicates.
///
pub fn names(parts: List(Part)) -> List(String) {
  parts
  |> list.filter_map(fn(part) { option.to_result(part.name, Nil) })
  |> list.unique
}

fn is_text_field(part: Part, name: String) -> Bool {
  part.name == Some(name) && part.filename == None
}

fn is_file(part: Part, name: String) -> Bool {
  part.name == Some(name) && option.is_some(part.filename)
}

/// Returns the part when its media type is one of `allowed`, ignoring ASCII
/// case and parameters such as `charset`.
///
/// Returns `Error(DisallowedContentType(content_type))` otherwise. A part
/// with no Content-Type is checked as `""`. The Content-Type is what the
/// client sent, so check the bytes too when it matters.
///
/// ## Examples
///
/// ```gleam
/// allowed_content_types(avatar, ["image/png", "image/jpeg"])
/// // -> Ok(avatar)
/// ```
///
pub fn allowed_content_types(
  part: Part,
  allowed: List(String),
) -> Result(Part, MultipartError) {
  let actual = option.unwrap(part.content_type, "")
  let media_type = strip_parameters(actual)
  case
    list.any(allowed, fn(a) { text.equals_ci(strip_parameters(a), media_type) })
  {
    True -> Ok(part)
    False -> Error(DisallowedContentType(actual))
  }
}

fn strip_parameters(value: String) -> String {
  case string.split_once(value, on: ";") {
    Ok(#(media_type, _)) -> string.trim(media_type)
    Error(Nil) -> string.trim(value)
  }
}

// Encoding --------------------------------------------------------------------

/// Encodes parts with the given boundary.
///
/// Returns `Error(InvalidBoundary(boundary))` when the boundary is empty,
/// longer than 70 characters, ends in a space or contains a character RFC
/// 2046 does not allow. Use `encode_form` to get a random boundary instead.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(title) = new_field(name: "title", value: "hi")
/// encode([title], "b")
/// // -> Ok(<<
/// //   "--b\r\n",
/// //   "Content-Disposition: form-data; name=\"title\"\r\n\r\n",
/// //   "hi\r\n",
/// //   "--b--\r\n",
/// // >>)
/// ```
///
/// ```gleam
/// encode([], "")
/// // -> Error(InvalidBoundary(""))
/// ```
///
pub fn encode(
  parts: List(Part),
  boundary: String,
) -> Result(BitArray, MultipartError) {
  use <- bool.guard(
    when: !text.is_valid_boundary(boundary),
    return: Error(InvalidBoundary(boundary)),
  )
  Ok(encode_with_valid_boundary(parts, boundary))
}

fn encode_with_valid_boundary(parts: List(Part), boundary: String) -> BitArray {
  parts
  |> list.map(fn(part) {
    <<
      "--":utf8,
      boundary:utf8,
      "\r\n":utf8,
      header_block.encode_block(part.headers):bits,
      "\r\n":utf8,
      part.body:bits,
      "\r\n":utf8,
    >>
  })
  |> list.append([<<"--":utf8, boundary:utf8, "--\r\n":utf8>>])
  |> bit_array.concat
}

/// Encodes parts as `multipart/form-data` with a new random boundary and
/// returns `#(content_type, body)`, where `content_type` is the value for
/// the HTTP `Content-Type` header.
///
/// The boundary comes from `int.random`, which is not cryptographically
/// strong.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(title) = new_field(name: "title", value: "hi")
/// let #(content_type, body) = encode_form([title])
/// // content_type -> "multipart/form-data; boundary=----multipartkit-..."
/// ```
///
pub fn encode_form(parts: List(Part)) -> #(String, BitArray) {
  let boundary = "----multipartkit-" <> random_boundary_characters(24, "")
  #(
    "multipart/form-data; boundary=" <> boundary,
    encode_with_valid_boundary(parts, boundary),
  )
}

fn random_boundary_characters(remaining: Int, characters: String) -> String {
  case remaining {
    0 -> characters
    _ -> {
      let character = string.lowercase(int.to_base36(int.random(36)))
      random_boundary_characters(remaining - 1, characters <> character)
    }
  }
}
