//// A question carries both its wire representation and its answer decoder.
//// Choice decoding closes over the caller's alternatives, so an unknown label
//// cannot escape as a domain value. Batches preserve that relationship.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import jevelin/content.{type Content}
import jevelin/internal/wire
import jevelin/probability.{type Probability}

/// A wire question paired with the only decoder that can answer it.
pub opaque type Question(answer) {
  Question(body: List(#(String, Json)), decoder: Decoder(answer))
}

/// Invalid local criteria are rejected before any network request.
pub type BuildError {
  /// Choice requires one to 255 alternatives, inclusive.
  ChoiceCount(actual: Int)

  /// A label would overwrite a previous alternative in the JSON object.
  DuplicateLabel(label: String)

  /// Score requires two to ten ordered levels, inclusive.
  ScoreCount(actual: Int)
}

/// Maps a wire label to a caller-owned domain value.
pub type Alternative(value) {
  Alternative(
    /// The label Jev evaluates and returns.
    label: String,
    /// The typed value returned when this label wins.
    value: value,
    /// An optional description; None encodes JSON null.
    description: Option(Content),
  )
}

/// A selected domain value and the distribution over all supplied alternatives.
pub type Choice(value) {
  Choice(
    /// The selected alternative, converted to the caller's type.
    selected: value,
    /// Provider-reported concentration of the distribution.
    confidence: Probability,
    /// Domain values and probabilities in request order.
    probabilities: List(#(value, Probability)),
  )
}

/// A probability-weighted score; it may fall between rubric levels.
pub type Score {
  Score(
    /// Expected zero-based rubric index.
    value: Float,
    /// Provider-reported concentration of the distribution.
    confidence: Probability,
    /// Structured descriptions keyed by zero-based index.
    legend: Dict(String, Content),
    /// Level probabilities keyed by zero-based index.
    probabilities: Dict(String, Probability),
  )
}

/// Creates a yes/no probability question, with no implicit threshold.
///
/// ## Examples
///
/// ```gleam
/// question.noul(content.Text("Does the passage answer the question?"))
/// ```
pub fn noul(instructions: Content) -> Question(Probability) {
  noul_with_criteria(instructions, None, None)
}

/// Defines optional evidence for each side of a yes/no question.
///
/// ## Examples
///
/// ```gleam
/// question.noul_with_criteria(content.Text("Relevant?"),
///   Some(content.Text("Directly answers the query")), None)
/// ```
pub fn noul_with_criteria(
  instructions: Content,
  yes: Option(Content),
  no: Option(Content),
) -> Question(Probability) {
  let criteria =
    list.filter_map([#("true", yes), #("false", no)], fn(pair) {
      case pair.1 {
        Some(value) -> Ok(#(pair.0, content.encode(value)))
        None -> Error(Nil)
      }
    })
  let extra = case criteria {
    [] -> []
    [_, ..] -> [#("criteria", json.object(criteria))]
  }
  let decoder = {
    use _ <- decode.field("type", tag("noul"))
    use value <- decode.field("noul", probability.decoder())
    decode.success(value)
  }
  Question(body: body("noul", instructions, extra), decoder:)
}

/// Creates a Choice whose selected value has the caller's own type.
///
/// ## Examples
///
/// ```gleam
/// question.choice(content.Text("Which queue?"), [
///   question.Alternative("review", Review, None),
///   question.Alternative("build", Build, None),
/// ])
/// ```
pub fn choice(
  instructions: Content,
  alternatives: List(Alternative(a)),
) -> Result(Question(Choice(a)), BuildError) {
  let count = list.length(alternatives)
  case alternatives {
    [first, ..] if count <= 255 -> {
      let labels = list.map(alternatives, fn(a) { a.label })
      case duplicate(labels) {
        Some(label) -> Error(DuplicateLabel(label))
        None ->
          Ok(Question(
            body: body("choice", instructions, [
              #(
                "criteria",
                json.object(
                  list.map(alternatives, fn(a) {
                    #(a.label, json.nullable(a.description, content.encode))
                  }),
                ),
              ),
            ]),
            decoder: choice_decoder(first, alternatives),
          ))
      }
    }
    _ -> Error(ChoiceCount(count))
  }
}

/// Creates a score over two to ten descriptions in increasing order.
///
/// ## Examples
///
/// ```gleam
/// question.score(content.Text("Relevance?"), [
///   content.Text("Unrelated"), content.Text("Useful"),
/// ])
/// ```
pub fn score(
  instructions: Content,
  levels: List(Content),
) -> Result(Question(Score), BuildError) {
  let count = list.length(levels)
  case count >= 2 && count <= 10 {
    False -> Error(ScoreCount(count))
    True ->
      Ok(Question(
        body: body("score", instructions, [
          #("criteria", json.array(levels, content.encode)),
        ]),
        decoder: score_decoder(count),
      ))
  }
}

/// Encodes this question for a named batch entry.
///
/// ## Examples
///
/// ```gleam
/// question.noul(content.Text("Relevant?")) |> question.encode
/// ```
pub fn encode(question: Question(a)) -> Json {
  json.object(question.body)
}

/// Omits optional instructions, leaving interpretation to the criteria.
/// The OpenAPI schema permits omission even though the prose marks it required.
///
/// ## Examples
///
/// ```gleam
/// question.noul(content.Text("")) |> question.without_instructions
/// ```
pub fn without_instructions(question: Question(a)) -> Question(a) {
  let body = list.filter(question.body, fn(field) { field.0 != "instructions" })
  Question(..question, body:)
}

/// Returns the request-bound decoder used by the batch combinators.
///
/// ## Examples
///
/// ```gleam
/// let q = question.noul(content.Text("Relevant?"))
/// json.parse("{\"type\":\"noul\",\"noul\":0.9}", question.decoder(q))
/// ```
pub fn decoder(question: Question(a)) -> Decoder(a) {
  question.decoder
}

fn body(
  kind: String,
  instructions: Content,
  extra: List(#(String, Json)),
) -> List(#(String, Json)) {
  [
    #("type", json.string(kind)),
    #("instructions", content.encode(instructions)),
    ..extra
  ]
}

fn tag(expected: String) -> Decoder(String) {
  wire.checked(decode.string, expected, fn(actual) { actual == expected })
}

fn choice_decoder(
  first: Alternative(a),
  alternatives: List(Alternative(a)),
) -> Decoder(Choice(a)) {
  let labels = list.map(alternatives, fn(a) { a.label })
  let values =
    dict.from_list(list.map(alternatives, fn(a) { #(a.label, a.value) }))
  let selected = {
    use label <- decode.then(decode.string)
    case dict.get(values, label) {
      Ok(value) -> decode.success(value)
      Error(Nil) -> decode.failure(first.value, "a requested choice label")
    }
  }
  use _ <- decode.field("type", tag("choice"))
  use selected <- decode.field("choice", selected)
  use confidence <- decode.field("confidence", probability.decoder())
  use probabilities <- decode.field("probabilities", distribution(labels))

  // The distribution decoder already proved every alternative is present.
  // Filtering only projects the validated map back into request order.
  let ordered =
    list.filter_map(alternatives, fn(a) {
      dict.get(probabilities, a.label)
      |> result.map(fn(p) { #(a.value, p) })
    })
  decode.success(Choice(selected:, confidence:, probabilities: ordered))
}

fn score_decoder(count: Int) -> Decoder(Score) {
  let labels =
    list.repeat(Nil, count)
    |> list.index_map(fn(_, index) { int.to_string(index) })
  use _ <- decode.field("type", tag("score"))
  use value <- decode.field("score", wire.bounded_number(0, count - 1))
  use confidence <- decode.field("confidence", probability.decoder())
  use legend <- decode.field(
    "legend",
    wire.checked(
      decode.dict(decode.string, content.decoder()),
      "a legend for every requested level",
      fn(d) { same_keys(d, labels) },
    ),
  )
  use probabilities <- decode.field("probabilities", distribution(labels))
  decode.success(Score(value:, confidence:, legend:, probabilities:))
}

fn distribution(labels: List(String)) -> Decoder(Dict(String, Probability)) {
  wire.checked(
    decode.dict(decode.string, probability.decoder()),
    "every requested probability, with total mass approximately one",
    fn(values) {
      let total =
        dict.fold(values, 0.0, fn(sum, _key, p) { sum +. probability.value(p) })
      same_keys(values, labels) && float.absolute_value(total -. 1.0) <=. 0.001
    },
  )
}

fn same_keys(values: Dict(String, a), labels: List(String)) -> Bool {
  dict.size(values) == list.length(labels)
  && list.all(labels, fn(key) { dict.has_key(values, key) })
}

fn duplicate(labels: List(String)) -> Option(String) {
  duplicate_loop(labels, dict.new())
}

fn duplicate_loop(
  labels: List(String),
  seen: Dict(String, Nil),
) -> Option(String) {
  case labels {
    [] -> None
    [label, ..rest] ->
      case dict.has_key(seen, label) {
        True -> Some(label)
        False -> duplicate_loop(rest, dict.insert(seen, label, Nil))
      }
  }
}
