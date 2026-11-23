import gleam/list
import gleam/option.{Some}
import metamon
import metamon/generator
import metamon/generator/range
import multipartkit
import support

// ---------- form encode → parse round-trip ----------

fn safe_field_name_generator() -> generator.Generator(String) {
  // `no_edges` drops the generator's edge cases, which include control
  // bytes and blank strings that `new_field` rejects. The rejection is
  // covered by its own properties below.
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
      let f = [] |> support.add_field(name, value)
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) =
        multipartkit.parse(body, content_type, multipartkit.default_limits)
      list.length(parts) == 1 && multipartkit.field(parts, name) == Ok(value)
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
        list.fold(over: entries, from: [], with: fn(acc, entry) {
          let #(name, value) = entry
          support.add_field(acc, name, value)
        })
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) =
        multipartkit.parse(body, content_type, multipartkit.default_limits)
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
        []
        |> support.add_field(name, value_a)
        |> support.add_field(name, value_b)
      let #(content_type, body) = multipartkit.encode_form(f)
      let assert Ok(parts) =
        multipartkit.parse(body, content_type, multipartkit.default_limits)
      // `field` returns the first matching value; `fields` returns
      // both in registration order.
      multipartkit.field(parts, name) == Ok(value_a)
      && multipartkit.fields(parts, name) == [value_a, value_b]
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
      let f = [] |> support.add_file(name, filename, content_type, body)
      let #(boundary_ct, encoded) = multipartkit.encode_form(f)
      let assert Ok(parts) =
        multipartkit.parse(encoded, boundary_ct, multipartkit.default_limits)
      let assert [single_part] = parts
      multipartkit.name(single_part) == Some(name)
      && multipartkit.filename(single_part) == Some(filename)
      && multipartkit.content_type(single_part) == Some(content_type)
      && multipartkit.body(single_part) == body
    },
  )
}

// ---------- header-breaking bytes are rejected (#40, #41) ----------

pub fn new_field_rejects_breaking_bytes_in_name_test() -> Nil {
  metamon.forall(
    generator.tuple2(
      generator.element_of(["\n", "\r", "\r\n", "\u{0}"]),
      safe_value_generator(),
    ),
    fn(input) {
      let #(injected, value) = input
      let name = "safe" <> injected <> "name"
      multipartkit.new_field(name:, value:)
      == Error(multipartkit.InvalidHeaderValue("Content-Disposition", name))
    },
  )
}

pub fn new_file_rejects_breaking_bytes_in_filename_test() -> Nil {
  metamon.forall(
    generator.element_of(["\n", "\r", "\r\n", "\u{0}"]),
    fn(injected) {
      let filename = "safe" <> injected <> "name.txt"
      multipartkit.new_file("field", filename, "text/plain", <<"x":utf8>>)
      == Error(multipartkit.InvalidHeaderValue("Content-Disposition", filename))
    },
  )
}

// ---------- part body preservation ----------

pub fn add_field_body_is_utf8_of_value_test() -> Nil {
  metamon.forall(safe_value_generator(), fn(value) {
    let f = [] |> support.add_field("name", value)
    let assert [single_part] = f
    multipartkit.body(single_part) == <<value:utf8>>
  })
}

pub fn add_file_preserves_byte_exact_body_test() -> Nil {
  metamon.forall(generator.bit_array(range.constant(0, 32)), fn(bytes) {
    let f =
      []
      |> support.add_file(
        "field",
        "file.bin",
        "application/octet-stream",
        bytes,
      )
    let assert [single_part] = f
    multipartkit.body(single_part) == bytes
  })
}

// ---------- empty form ----------

pub fn empty_form_parses_to_empty_part_list_test() -> Nil {
  let f = []
  let #(content_type, body) = multipartkit.encode_form(f)
  let assert Ok(parts) =
    multipartkit.parse(body, content_type, multipartkit.default_limits)
  assert parts == []
}
