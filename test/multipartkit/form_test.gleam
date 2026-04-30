import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import multipartkit/encoder
import multipartkit/form
import multipartkit/infer
import multipartkit/parser
import multipartkit/part

pub fn empty_form_test() {
  form.new()
  |> form.parts
  |> should.equal([])
}

pub fn add_field_appends_in_order_test() {
  let f =
    form.new()
    |> form.add_field("a", "1")
    |> form.add_field("b", "2")
  let parts = form.parts(f)
  case parts {
    [first, second] -> {
      part.name(first) |> should.equal(Some("a"))
      part.body(first) |> should.equal(<<"1":utf8>>)
      part.name(second) |> should.equal(Some("b"))
      part.body(second) |> should.equal(<<"2":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn add_file_sets_metadata_test() {
  let f =
    form.new()
    |> form.add_file("upload", "doc.pdf", "application/pdf", <<"%PDF":utf8>>)
  let assert [the_part] = form.parts(f)
  part.name(the_part) |> should.equal(Some("upload"))
  part.filename(the_part) |> should.equal(Some("doc.pdf"))
  part.content_type(the_part) |> should.equal(Some("application/pdf"))
}

pub fn add_file_auto_falls_through_to_octet_stream_test() {
  // The default infer module returns None for both helpers in v0.1.0.
  let f =
    form.new()
    |> form.add_file_auto("blob", "any.bin", <<1, 2, 3>>)
  let assert [the_part] = form.parts(f)
  part.content_type(the_part) |> should.equal(Some("application/octet-stream"))
}

pub fn add_file_auto_with_filename_inferer_test() {
  let inferer =
    infer.Inferer(
      from_filename: fn(name) {
        case name {
          "x.png" -> Some("image/png")
          _ -> None
        }
      },
      from_bytes: fn(_) { None },
    )
  let f =
    form.new()
    |> form.add_file_auto_with("blob", "x.png", <<1, 2>>, inferer)
  let assert [the_part] = form.parts(f)
  part.content_type(the_part) |> should.equal(Some("image/png"))
}

pub fn add_file_auto_with_bytes_inferer_fallback_test() {
  let inferer =
    infer.Inferer(from_filename: fn(_) { None }, from_bytes: fn(_bytes) {
      Some("application/x-custom")
    })
  let f =
    form.new()
    |> form.add_file_auto_with("blob", "no-ext", <<0, 1, 2>>, inferer)
  let assert [the_part] = form.parts(f)
  part.content_type(the_part) |> should.equal(Some("application/x-custom"))
}

pub fn unsafe_add_part_inserts_verbatim_test() {
  let manual =
    part.new(
      headers: [#("X-Custom", "v")],
      name: None,
      filename: None,
      content_type: None,
      body: <<"raw":utf8>>,
    )
  let f =
    form.new()
    |> form.unsafe_add_part(manual)
  let assert [the_part] = form.parts(f)
  part.all_headers(the_part) |> should.equal([#("X-Custom", "v")])
  part.name(the_part) |> should.equal(None)
}

pub fn form_round_trips_with_multiple_parts_test() {
  let f =
    form.new()
    |> form.add_field("name", "Alice")
    |> form.add_field("notes", "hello world")
    |> form.add_file("avatar", "a.png", "image/png", <<0x89, 0x50, 0x4E, 0x47>>)
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok(parts) = parser.parse(body, content_type)
  case parts {
    [first, second, third] -> {
      part.name(first) |> should.equal(Some("name"))
      part.body(first) |> should.equal(<<"Alice":utf8>>)
      part.name(second) |> should.equal(Some("notes"))
      part.body(second) |> should.equal(<<"hello world":utf8>>)
      part.name(third) |> should.equal(Some("avatar"))
      part.filename(third) |> should.equal(Some("a.png"))
      part.content_type(third) |> should.equal(Some("image/png"))
      part.body(third) |> should.equal(<<0x89, 0x50, 0x4E, 0x47>>)
    }
    _ -> should.fail()
  }
}

pub fn add_field_strips_crlf_from_name_test() {
  // CR/LF in name would otherwise produce a header line that the parser
  // re-reads as multiple headers. The safe builder strips them silently.
  let f =
    form.new()
    |> form.add_field("dangerous\r\nX-Injected: yes", "value")
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok([the_part]) = parser.parse(body, content_type)
  // After CR/LF stripping the round-tripped name no longer contains the
  // injected newline.
  part.name(the_part) |> should.equal(Some("dangerousX-Injected: yes"))
  // Only the legitimate Content-Disposition header is produced.
  part.all_headers(the_part)
  |> should.equal([
    #("Content-Disposition", "form-data; name=\"dangerousX-Injected: yes\""),
  ])
}

pub fn add_file_strips_crlf_from_filename_test() {
  let f =
    form.new()
    |> form.add_file(
      "upload",
      "evil\r\nname.txt",
      "application/octet-stream",
      <<>>,
    )
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok([the_part]) = parser.parse(body, content_type)
  // Re-parsed filename has the CRLF removed.
  part.filename(the_part) |> should.equal(Some("evilname.txt"))
}

pub fn add_file_strips_crlf_from_content_type_test() {
  // A Content-Type that injects "\r\nX-Evil: 1" must not produce an extra
  // header on the wire.
  let f =
    form.new()
    |> form.add_file("upload", "x.txt", "text/plain\r\nX-Evil: 1", <<"hi":utf8>>)
  let assert [the_part] = form.parts(f)
  // Cached metadata is sanitized to match the serialized form.
  part.content_type(the_part)
  |> should.equal(Some("text/plainX-Evil: 1"))
  // Round-trip the form and confirm only the intended Content-Type survives.
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok([reparsed]) = parser.parse(body, content_type)
  part.content_type(reparsed)
  |> should.equal(Some("text/plainX-Evil: 1"))
  // No spurious X-Evil header was injected.
  case
    list.find(part.all_headers(reparsed), fn(entry) { entry.0 == "X-Evil" })
  {
    Error(Nil) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn add_file_auto_with_strips_crlf_from_inferred_content_type_test() {
  let inferer =
    infer.Inferer(
      from_filename: fn(_) { Some("text/plain\r\nX-Evil: 1") },
      from_bytes: fn(_) { None },
    )
  let f =
    form.new()
    |> form.add_file_auto_with("upload", "x.txt", <<"hi":utf8>>, inferer)
  let assert [the_part] = form.parts(f)
  part.content_type(the_part)
  |> should.equal(Some("text/plainX-Evil: 1"))
}

pub fn form_metadata_matches_round_tripped_parts_test() {
  // The cached `name` / `filename` fields on a Form's parts must equal what
  // a parse-after-encode round-trip would produce. Otherwise callers see
  // different values from `form.parts` and `parse(encode_form(form))`.
  let f =
    form.new()
    |> form.add_field("dangerous\r\nX-Inj: 1", "value")
    |> form.add_file("upload", "evil\r\nname.txt", "text/plain\r\nX-Evil: 1", <<
      "data":utf8,
    >>)
  let cached = form.parts(f)
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok(reparsed) = parser.parse(body, content_type)
  case cached, reparsed {
    [c1, c2], [r1, r2] -> {
      part.name(c1) |> should.equal(part.name(r1))
      part.name(c2) |> should.equal(part.name(r2))
      part.filename(c2) |> should.equal(part.filename(r2))
      part.content_type(c2) |> should.equal(part.content_type(r2))
    }
    _, _ -> should.fail()
  }
}

pub fn add_field_with_quote_in_value_round_trips_test() {
  // Quotes inside the field value go to the part body, not to a header.
  let f =
    form.new()
    |> form.add_field("k", "value with \" quote")
  let #(content_type, body) = encoder.encode_form(f)
  let assert Ok([p]) = parser.parse(body, content_type)
  part.body(p) |> should.equal(<<"value with \" quote":utf8>>)
}
