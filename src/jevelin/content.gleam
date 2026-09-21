//// Content accepted by Jev at a state, instruction, or rubric boundary.
//// Top-level scalars other than strings are excluded by construction. Nested
//// objects and arrays retain ordinary JSON values, including numbers and null.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import jevelin/internal/wire

/// Text or structured context. Numbers and booleans belong inside a container.
pub type Content {
  /// Natural-language text.
  Text(value: String)

  /// Named JSON fields. Field names must be unique.
  Object(fields: List(#(String, Json)))

  /// Ordered JSON values.
  Array(values: List(Json))
}

/// Encodes content without serializing structured data into a quoted string.
///
/// ## Examples
///
/// ```gleam
/// content.encode(content.Text("hello")) |> json.to_string
/// // => "\"hello\""
/// ```
pub fn encode(content: Content) -> Json {
  case content {
    Text(value) -> json.string(value)
    Object(fields) -> json.object(fields)
    Array(values) -> json.preprocessed_array(values)
  }
}

/// Decodes a structured score legend using the same shapes as request content.
///
/// ## Examples
///
/// ```gleam
/// json.parse("\"urgent\"", content.decoder())
/// // => Ok(content.Text("urgent"))
/// ```
pub fn decoder() -> Decoder(Content) {
  decode.one_of(decode.map(decode.string, Text), [
    decode.map(wire.object_decoder(), Object),
    decode.map(decode.list(wire.json_decoder()), Array),
  ])
}
