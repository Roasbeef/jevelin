//// Probabilities and confidence values are bounded numbers, not booleans.
//// A threshold decision remains the caller's policy. Confidence describes a
//// distribution's concentration, not a measured chance of correctness.

import gleam/dynamic/decode.{type Decoder}
import jevelin/internal/wire

/// A finite number between zero and one, inclusive.
pub opaque type Probability {
  Probability(value: Float)
}

/// Validates a probability without clamping an invalid value.
///
/// ## Examples
///
/// ```gleam
/// probability.new(1.2) // => Error(Nil)
/// ```
pub fn new(value: Float) -> Result(Probability, Nil) {
  case value >=. 0.0 && value <=. 1.0 {
    True -> Ok(Probability(value))
    False -> Error(Nil)
  }
}

/// Returns the bounded numeric value for ranking and threshold comparisons.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(p) = probability.new(0.8)
/// probability.value(p) // => 0.8
/// ```
pub fn value(probability: Probability) -> Float {
  probability.value
}

/// Decodes a JSON number in the probability interval.
///
/// ## Examples
///
/// ```gleam
/// json.parse("2", probability.decoder()) // => Error(...)
/// ```
pub fn decoder() -> Decoder(Probability) {
  wire.bounded_number(0, 1) |> decode.map(Probability)
}
