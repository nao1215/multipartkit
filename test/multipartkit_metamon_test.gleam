import gleam/list
import gleam/option.{Some}
import metamon
import metamon/generator
import metamon/generator/range
import multipartkit
import multipartkit/form
import multipartkit/part
import multipartkit/query as mquery

// ---------- form encode → parse round-trip ----------

fn safe_field_name_generator() -> generator.Generator(String) {
  // `no_edges` strips the generator's edge list (which includes the
  // canonical control-byte / whitespace strings that surface the
  // CR/LF strip bug from #40 / #41). The strict-name property
  // tests below pin the strip behaviour explicitly; this generator
  // stays inside the unambiguous shape for the round-trip.
  generator.string_alphanumeric(range.constant(1, 8))
  |> generator.no_edges
}

fn safe_value_generator() -> generator.Generator(String) {
  generator.string_alphanumeric(range.constant(0, 16))
  |> generator.no_edges
}

pub fn form_with_one_field_round_trips_test() -> Nil {
  metamon.forall(
    generator.tuple2(safe_field_name_generator(), safe_value_generator()),
    fn(pair) {
      let #(name, value) = pair
      let f = form.new() |> form.add_field(name, value)
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) = multipartkit.parse(body, content_type)
      list.length(parts) == 1 && mquery.field(parts, name) == Some(value)
    },
  )
}

pub fn form_with_multiple_fields_preserves_count_test() -> Nil {
  metamon.forall(
    generator.list_of(
      generator.tuple2(safe_field_name_generator(), safe_value_generator()),
      range.constant(0, 5),
    ),
    fn(entries) {
      let f =
        list.fold(over: entries, from: form.new(), with: fn(acc, entry) {
          let #(name, value) = entry
          form.add_field(acc, name, value)
        })
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) = multipartkit.parse(body, content_type)
      list.length(parts) == list.length(entries)
    },
  )
}

pub fn form_field_lookup_returns_first_for_duplicate_names_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      safe_field_name_generator(),
      generator.tuple2(safe_value_generator(), safe_value_generator()),
    ),
    fn(input) {
      let #(name, values) = input
      let #(value_a, value_b) = values
      let f =
        form.new()
        |> form.add_field(name, value_a)
        |> form.add_field(name, value_b)
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) = multipartkit.parse(body, content_type)
      // `field` returns the first matching value; `fields` returns
      // both in registration order.
      mquery.field(parts, name) == Some(value_a)
      && mquery.fields(parts, name) == [value_a, value_b]
    },
  )
}

pub fn form_file_round_trips_name_filename_content_type_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      safe_field_name_generator(),
      generator.tuple2(
        generator.string_alphanumeric(range.constant(1, 8)),
        generator.bit_array(range.constant(0, 16)),
      ),
    ),
    fn(input) {
      let #(name, rest) = input
      let #(filename_stem, body) = rest
      let filename = filename_stem <> ".bin"
      let content_type = "application/octet-stream"
      let f = form.new() |> form.add_file(name, filename, content_type, body)
      let #(boundary_ct, encoded) = multipartkit.encode_form(f)
      let assert Ok(parts) = multipartkit.parse(encoded, boundary_ct)
      let assert [single_part] = parts
      part.name(single_part) == Some(name)
      && part.filename(single_part) == Some(filename)
      && part.content_type(single_part) == Some(content_type)
      && part.body(single_part) == body
    },
  )
}

// ---------- form.add_field strips CR / LF / NUL (current behaviour) ----------

pub fn add_field_strips_lf_from_name_test() -> Nil {
  // Pin the existing (documented) sanitization behaviour: CR / LF /
  // NUL bytes are stripped from the name before it reaches the
  // wire. If the suite later switches to returning Result(Form, _)
  // for bad names (#40), this test should be replaced with the
  // explicit Error variant assertion.
  metamon.forall(
    generator.tuple2(
      generator.element_of(["\n", "\r", "\r\n", "\u{0}"]),
      safe_value_generator(),
    ),
    fn(input) {
      let #(injected, value) = input
      let f = form.new() |> form.add_field("safe" <> injected <> "name", value)
      let assert [single_part] = form.parts(f)
      part.name(single_part) == Some("safename")
    },
  )
}

pub fn add_file_strips_lf_from_filename_test() -> Nil {
  metamon.forall(
    generator.element_of(["\n", "\r", "\r\n", "\u{0}"]),
    fn(injected) {
      let f =
        form.new()
        |> form.add_file(
          "field",
          "safe" <> injected <> "name.txt",
          "text/plain",
          <<"x":utf8>>,
        )
      let assert [single_part] = form.parts(f)
      part.filename(single_part) == Some("safename.txt")
    },
  )
}

// ---------- part body preservation ----------

pub fn add_field_body_is_utf8_of_value_test() -> Nil {
  metamon.forall(safe_value_generator(), fn(value) {
    let f = form.new() |> form.add_field("name", value)
    let assert [single_part] = form.parts(f)
    part.body(single_part) == <<value:utf8>>
  })
}

pub fn add_file_preserves_byte_exact_body_test() -> Nil {
  metamon.forall(generator.bit_array(range.constant(0, 32)), fn(bytes) {
    let f =
      form.new()
      |> form.add_file("field", "file.bin", "application/octet-stream", bytes)
    let assert [single_part] = form.parts(f)
    part.body(single_part) == bytes
  })
}

// ---------- empty form ----------

pub fn empty_form_parses_to_empty_part_list_test() -> Nil {
  let f = form.new()
  let #(content_type, body) = multipartkit.encode_form(f)
  let assert Ok(parts) = multipartkit.parse(body, content_type)
  assert parts == []
}
