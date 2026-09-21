//// Applicative composition keeps each question coupled to its answer type.
//// All questions are known before transport runs; no question can depend on an
//// answer from the same request. map2 combines heterogeneous answers into a
//// domain record, while all handles dynamically sized homogeneous batches.

import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import jevelin/internal/wire
import jevelin/question.{type Question}

/// Independent named questions and a decoder for their combined answer.
pub opaque type Batch(answer) {
  Batch(entries: List(#(String, Json)), decoder: Decoder(answer))
}

/// Invalid question sets cannot be prepared for transport.
pub type BuildError {
  /// The API requires at least one question.
  EmptyBatch

  /// JSON object names must not silently overwrite another question.
  DuplicateName(name: String)
}

/// Names one typed question in a batch.
///
/// ## Examples
///
/// ```gleam
/// batch.question("relevant", question.noul(content.Text("Relevant?")))
/// ```
pub fn question(name: String, question: Question(a)) -> Batch(a) {
  Batch(
    entries: [#(name, question.encode(question))],
    decoder: decode.at([name], question.decoder(question)),
  )
}

/// Transforms the combined answer without changing the request.
///
/// ## Examples
///
/// ```gleam
/// batch.question("relevant", question.noul(content.Text("Relevant?")))
/// |> batch.map(probability.value)
/// ```
pub fn map(batch: Batch(a), f: fn(a) -> b) -> Batch(b) {
  Batch(entries: batch.entries, decoder: decode.map(batch.decoder, f))
}

/// Combines independent batches into a typed tuple or domain record.
/// Duplicate names are rejected when the final request is prepared.
///
/// ## Examples
///
/// ```gleam
/// batch.map2(route_batch, urgency_batch, fn(route, urgent) {
///   Signals(route, urgent)
/// })
/// ```
pub fn map2(left: Batch(a), right: Batch(b), f: fn(a, b) -> c) -> Batch(c) {
  let decoder = {
    use a <- decode.then(left.decoder)
    use b <- decode.then(right.decoder)
    decode.success(f(a, b))
  }
  Batch(entries: list.append(left.entries, right.entries), decoder:)
}

/// Combines a list of batches, preserving input order in the answers.
/// An empty list is rejected when preparing a request.
///
/// ## Examples
///
/// ```gleam
/// passages |> list.map(score_passage) |> batch.all
/// ```
pub fn all(batches: List(Batch(a))) -> Batch(List(a)) {
  let initial = Batch(entries: [], decoder: decode.success([]))
  list.fold(list.reverse(batches), initial, fn(rest, item) {
    map2(item, rest, fn(value, values) { [value, ..values] })
  })
}

/// Validates names and encodes the question object before transport runs.
///
/// ## Examples
///
/// ```gleam
/// batch.all([]) |> batch.encode // => Error(batch.EmptyBatch)
/// ```
pub fn encode(batch: Batch(a)) -> Result(Json, BuildError) {
  case batch.entries {
    [] -> Error(EmptyBatch)
    [_, ..] -> {
      use _ <- result.try(
        list.try_fold(batch.entries, dict.new(), fn(seen, entry) {
          case dict.has_key(seen, entry.0) {
            True -> Error(DuplicateName(entry.0))
            False -> Ok(dict.insert(seen, entry.0, Nil))
          }
        }),
      )
      Ok(json.object(batch.entries))
    }
  }
}

/// Decodes exactly the answer names requested by this batch.
/// Additional metadata inside individual answers remains forward-compatible.
///
/// ## Examples
///
/// ```gleam
/// json.parse(response_answers, batch.decoder(questions))
/// ```
pub fn decoder(batch: Batch(a)) -> Decoder(a) {
  let names = list.map(batch.entries, fn(entry) { entry.0 })
  use _ <- decode.then(
    wire.checked(
      decode.dict(decode.string, decode.dynamic),
      "the requested answer names",
      fn(fields) {
        dict.size(fields) == list.length(names)
        && list.all(names, fn(name) { dict.has_key(fields, name) })
      },
    ),
  )
  batch.decoder
}
