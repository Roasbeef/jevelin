//// Shared total decoders. Validation keeps the decoded value as a failure
//// placeholder; Gleam's decoder never returns that placeholder on success.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/option

/// Accepts a bounded JSON number on both compilation targets.
/// Integers must be bounded before conversion: BEAM can decode integers too
/// large for a Float, and int.to_float would otherwise raise badarg.
pub fn bounded_number(minimum: Int, maximum: Int) -> Decoder(Float) {
  let integer = {
    use value <- decode.then(decode.int)
    case value >= minimum && value <= maximum {
      True -> decode.success(int.to_float(value))
      False -> decode.failure(0.0, "a number within the permitted interval")
    }
  }
  checked(
    decode.one_of(decode.float, [integer]),
    "a number within the permitted interval",
    fn(value) {
      value >=. int.to_float(minimum) && value <=. int.to_float(maximum)
    },
  )
}

/// Refines a decoder without throwing or coercing malformed wire values.
pub fn checked(
  decoder: Decoder(a),
  expected: String,
  accepts: fn(a) -> Bool,
) -> Decoder(a) {
  use value <- decode.then(decoder)
  case accepts(value) {
    True -> decode.success(value)
    False -> decode.failure(value, expected)
  }
}

/// Decodes and re-encodes arbitrary nested JSON without losing null values.
pub fn json_decoder() -> Decoder(Json) {
  decode.one_of(decode.map(decode.string, json.string), [
    decode.map(decode.int, json.int),
    decode.map(decode.float, json.float),
    decode.map(decode.bool, json.bool),
    decode.map(
      decode.list(decode.recursive(json_decoder)),
      json.preprocessed_array,
    ),
    decode.map(object_decoder(), json.object),
    decode.map(decode.optional(decode.string), fn(value) {
      case value {
        option.None -> json.null()
        option.Some(text) -> json.string(text)
      }
    }),
  ])
}

/// Object fields are decoded through the recursive JSON decoder.
pub fn object_decoder() -> Decoder(List(#(String, Json))) {
  decode.dict(decode.string, decode.recursive(json_decoder))
  |> decode.map(dict.to_list)
}
