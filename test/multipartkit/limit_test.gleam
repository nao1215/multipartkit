import gleeunit/should
import multipartkit/limit

pub fn new_ok_returns_limits_test() {
  let assert Ok(l) =
    limit.new(
      max_body_bytes: 1000,
      max_part_bytes: 500,
      max_parts: 5,
      max_header_bytes: 256,
    )
  l |> limit.max_body_bytes |> should.equal(1000)
  l |> limit.max_part_bytes |> should.equal(500)
  l |> limit.max_parts |> should.equal(5)
  l |> limit.max_header_bytes |> should.equal(256)
}

pub fn new_rejects_zero_max_body_bytes_test() {
  case
    limit.new(
      max_body_bytes: 0,
      max_part_bytes: 500,
      max_parts: 5,
      max_header_bytes: 256,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: g)) -> {
      f |> should.equal("max_body_bytes")
      g |> should.equal(0)
    }
    Ok(_) -> should.fail()
  }
}

pub fn new_rejects_negative_max_part_bytes_test() {
  case
    limit.new(
      max_body_bytes: 1000,
      max_part_bytes: -1,
      max_parts: 5,
      max_header_bytes: 256,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: g)) -> {
      f |> should.equal("max_part_bytes")
      g |> should.equal(-1)
    }
    Ok(_) -> should.fail()
  }
}

pub fn new_rejects_zero_max_parts_test() {
  case
    limit.new(
      max_body_bytes: 1000,
      max_part_bytes: 500,
      max_parts: 0,
      max_header_bytes: 256,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: _)) ->
      f |> should.equal("max_parts")
    Ok(_) -> should.fail()
  }
}

pub fn new_rejects_zero_max_header_bytes_test() {
  case
    limit.new(
      max_body_bytes: 1000,
      max_part_bytes: 500,
      max_parts: 5,
      max_header_bytes: 0,
    )
  {
    Error(limit.NonPositiveLimit(field: f, given: _)) ->
      f |> should.equal("max_header_bytes")
    Ok(_) -> should.fail()
  }
}

pub fn default_limits_passes_validation_test() {
  let d = limit.default_limits()
  let assert Ok(l) =
    limit.new(
      max_body_bytes: limit.max_body_bytes(d),
      max_part_bytes: limit.max_part_bytes(d),
      max_parts: limit.max_parts(d),
      max_header_bytes: limit.max_header_bytes(d),
    )
  limit.max_body_bytes(l)
  |> should.equal(limit.max_body_bytes(d))
}
