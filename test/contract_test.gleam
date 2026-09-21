import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import jevelin
import jevelin/batch
import jevelin/content.{Text}
import jevelin/probability
import jevelin/question

type Route {
  Review
  Build
}

type Signals {
  Signals(
    route: question.Choice(Route),
    urgent: probability.Probability,
    relevance: question.Score,
  )
}

fn route_question() -> question.Question(question.Choice(Route)) {
  let assert Ok(q) =
    question.choice(Text("Which workflow?"), [
      question.Alternative("review", Review, Some(Text("Review existing code"))),
      question.Alternative("build", Build, None),
    ])
    as "valid alternatives"
  q
}

fn score_question() -> question.Question(question.Score) {
  let assert Ok(q) =
    question.score(Text("Relevance?"), [Text("Unrelated"), Text("Useful")])
    as "valid rubric"
  q
}

fn prepared(q: question.Question(a)) -> jevelin.Request(jevelin.Evaluation(a)) {
  let assert Ok(request) =
    jevelin.evaluate(Text("state"), batch.question("q", q))
    as "valid question"
  request
}

fn response(answer: String) -> jevelin.HttpResponse {
  jevelin.HttpResponse(
    200,
    [],
    "{\"model\":\"jev-1.13.0\",\"answers\":{\"q\":"
      <> answer
      <> "},\"usage\":{\"input_tokens\":392,\"output_tokens\":65}}",
  )
}

const choice_answer = "{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":0.78,\"probabilities\":{\"build\":0.15,\"review\":0.85}}"

const score_answer = "{\"type\":\"score\",\"score\":0.75,\"confidence\":0.8,\"legend\":{\"0\":\"Unrelated\",\"1\":\"Useful\"},\"probabilities\":{\"0\":0.25,\"1\":0.75}}"

pub fn mixed_batch_decodes_to_domain_record_test() {
  let questions =
    batch.map2(
      batch.map2(
        batch.question("route", route_question()),
        batch.question("urgent", question.noul(Text("Urgent?"))),
        fn(r, u) { #(r, u) },
      ),
      batch.question("relevance", score_question()),
      fn(pair, score) { Signals(pair.0, pair.1, score) },
    )
  let assert Ok(request) =
    jevelin.evaluate_with_model(Text("help"), "jev-1.13.0", questions)
    as "valid batch"
  let reply =
    "{\"model\":\"jev-1.13.0\",\"answers\":{\"relevance\":"
    <> score_answer
    <> ",\"urgent\":{\"type\":\"noul\",\"noul\":1},\"route\":"
    <> choice_answer
    <> "},\"usage\":{\"input_tokens\":392,\"output_tokens\":65}}"
  let assert Ok(output) =
    jevelin.decode_response(request, jevelin.HttpResponse(200, [], reply))
    as "typed response"
  assert output.model == "jev-1.13.0"
  assert output.usage == jevelin.Usage(392, 65)
  assert output.answers.route.selected == Review
  assert probability.value(output.answers.urgent) == 1.0
  assert output.answers.relevance.value == 0.75
  assert list.map(output.answers.route.probabilities, fn(pair) {
      #(pair.0, probability.value(pair.1))
    })
    == [#(Review, 0.85), #(Build, 0.15)]
}

pub fn request_encodes_structured_content_and_omits_credentials_test() {
  let state =
    content.Object([
      #("message", json.string("hello")),
      #("attempt", json.int(2)),
    ])
  let assert Ok(request) =
    jevelin.evaluate(state, batch.question("route", route_question()))
    as "valid batch"
  let http = jevelin.http_request(request)
  assert http.method == jevelin.Post
  assert http.path == "/v1/systemone"
  assert http.headers
    == [#("content-type", "application/json"), #("accept", "application/json")]
  let decoder = {
    use message <- decode.then(decode.at(["state", "message"], decode.string))
    use attempt <- decode.then(decode.at(["state", "attempt"], decode.int))
    use model <- decode.field("model", decode.string)
    use description <- decode.then(decode.at(
      ["questions", "route", "criteria", "build"],
      decode.optional(decode.string),
    ))
    decode.success(#(message, attempt, model, description))
  }
  assert json.parse(http.body, decoder) == Ok(#("hello", 2, "jev-latest", None))
}

pub fn noul_criteria_are_optional_and_preserve_structure_test() {
  let q =
    question.noul_with_criteria(
      Text("Useful?"),
      Some(content.Array([json.string("evidence"), json.null()])),
      None,
    )
  let encoded = question.encode(q) |> json.to_string
  let assert Ok(fields) =
    json.parse(
      encoded,
      decode.at(["criteria"], decode.dict(decode.string, decode.dynamic)),
    )
    as "criteria object"
  assert dict.keys(fields) == ["true"]
  let plain =
    question.noul(Text("Useful?")) |> question.encode |> json.to_string
  let assert Ok(fields) =
    json.parse(plain, decode.dict(decode.string, decode.dynamic))
    as "question object"
  assert !dict.has_key(fields, "criteria")
}

pub fn choice_rejects_duplicate_and_out_of_bounds_alternatives_test() {
  let alternative = question.Alternative("x", Review, None)
  let assert Error(question.DuplicateLabel("x")) =
    question.choice(Text("?"), [alternative, alternative])
    as "no silent overwrite"
  let assert Error(question.ChoiceCount(0)) = question.choice(Text("?"), [])
    as "nonempty alternatives"
  let alternatives =
    list.repeat(Nil, 256)
    |> list.index_map(fn(_, i) {
      question.Alternative(int.to_string(i), i, None)
    })
  let assert Error(question.ChoiceCount(256)) =
    question.choice(Text("?"), alternatives)
    as "provider limit"
  let assert Ok(_) = question.choice(Text("?"), list.take(alternatives, 255))
    as "inclusive upper boundary"
  let assert Ok(_) = question.choice(Text("?"), [alternative])
    as "single choice supported"
  Nil
}

pub fn score_rejects_unsupported_rubric_sizes_test() {
  list.each([0, 1, 11], fn(count) {
    let assert Error(question.ScoreCount(actual)) =
      question.score(Text("?"), list.repeat(Text("level"), count))
      as "unsupported rubric"
    assert actual == count
  })
  list.each([2, 10], fn(count) {
    let assert Ok(_) =
      question.score(Text("?"), list.repeat(Text("level"), count))
      as "inclusive rubric limits"
  })
}

pub fn preparation_rejects_empty_or_colliding_batches_test() {
  let assert Error(jevelin.InvalidBatch(batch.EmptyBatch)) =
    jevelin.evaluate(Text(""), batch.all([]))
    as "empty batch rejected"
  let q = batch.question("same", question.noul(Text("?")))
  let assert Error(jevelin.InvalidBatch(batch.DuplicateName("same"))) =
    jevelin.evaluate(Text(""), batch.map2(q, q, fn(a, b) { #(a, b) }))
    as "duplicate names rejected"
  let assert Error(jevelin.EmptyModel) =
    jevelin.evaluate_with_model(Text(""), " \n", q)
    as "blank model rejected"
}

pub fn wrong_answer_type_or_unknown_choice_is_rejected_test() {
  list.each(
    [
      "{\"type\":\"noul\",\"noul\":0.8}",
      "{\"type\":\"choice\",\"choice\":\"deploy\",\"confidence\":0.9,\"probabilities\":{\"review\":0.9,\"build\":0.1}}",
    ],
    fn(answer) {
      let assert Error(jevelin.InvalidResponse(_)) =
        jevelin.decode_response(prepared(route_question()), response(answer))
        as "request-bound choice decoder"
    },
  )
}

pub fn choice_requires_exact_probability_domain_and_mass_test() {
  list.each(
    [
      "{\"review\":1}",
      "{\"review\":0.5,\"build\":0.4,\"deploy\":0.1}",
      "{\"review\":0.3,\"build\":0.3}",
      "{\"review\":1.1,\"build\":-0.1}",
      "{\"review\":\"0.9\",\"build\":0.1}",
    ],
    fn(distribution) {
      let answer =
        "{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":0.9,\"probabilities\":"
        <> distribution
        <> "}"
      let assert Error(jevelin.InvalidResponse(_)) =
        jevelin.decode_response(prepared(route_question()), response(answer))
        as "invalid distribution rejected"
    },
  )
}

pub fn generated_probability_boundaries_test() {
  let q = prepared(question.noul(Text("?")))
  list.repeat(Nil, 1201)
  |> list.index_map(fn(_, i) { i - 100 })
  |> list.each(fn(i) {
    let value = int.to_float(i) /. 1000.0
    let answer =
      json.object([#("type", json.string("noul")), #("noul", json.float(value))])
      |> json.to_string
    let decoded = jevelin.decode_response(q, response(answer))
    case i >= 0 && i <= 1000 {
      True -> {
        let assert Ok(output) = decoded as "bounded probability accepted"
        assert probability.value(output.answers) == value
      }
      False -> {
        let assert Error(jevelin.InvalidResponse(_)) = decoded
          as "out-of-range probability rejected"
        Nil
      }
    }
  })
}

pub fn scores_preserve_structured_legends_test() {
  let answer =
    "{\"type\":\"score\",\"score\":0.5,\"confidence\":0.5,\"legend\":{\"0\":{\"examples\":[null,true,2,0.5,{\"text\":\"x\"}]},\"1\":[\"useful\",null]},\"probabilities\":{\"0\":0.5,\"1\":0.5}}"
  let assert Ok(output) =
    jevelin.decode_response(prepared(score_question()), response(answer))
    as "structured legend accepted"
  let assert Ok(level) = dict.get(output.answers.legend, "0") as "level present"
  let text = content.encode(level) |> json.to_string
  let assert Ok(examples) =
    json.parse(text, decode.at(["examples"], decode.list(decode.dynamic)))
    as "nested JSON preserved"
  assert list.length(examples) == 5
  let assert Ok(again) = json.parse(text, content.decoder()) as "roundtrip"
  assert content.encode(again) |> json.to_string == text
}

pub fn scores_reject_wrong_level_keys_and_range_test() {
  list.each(
    [
      "{\"type\":\"score\",\"score\":2,\"confidence\":0.5,\"legend\":{\"0\":\"a\",\"1\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
      "{\"type\":\"score\",\"score\":0.5,\"confidence\":0.5,\"legend\":{\"1\":\"a\",\"2\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
      "{\"type\":\"score\",\"score\":0.5,\"confidence\":2,\"legend\":{\"0\":\"a\",\"1\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
      "{\"type\":\"score\",\"score\":0.5,\"confidence\":0.5,\"legend\":{\"0\":null,\"1\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
    ],
    fn(answer) {
      let assert Error(jevelin.InvalidResponse(_)) =
        jevelin.decode_response(prepared(score_question()), response(answer))
        as "invalid score rejected"
    },
  )
}

pub fn missing_extra_and_malformed_answers_fail_test() {
  let q = prepared(question.noul(Text("?")))
  list.each(
    [
      "{}", "[]", "null", "not json",
      "{\"model\":\"m\",\"answers\":{},\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}",
      "{\"model\":\"m\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":0.5},\"extra\":{\"type\":\"noul\",\"noul\":0.5}},\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}",
      "{\"model\":\"m\",\"answers\":{\"q\":{\"type\":\"noul\",\"noul\":0.5}},\"usage\":{\"input_tokens\":-1,\"output_tokens\":0}}",
    ],
    fn(body) {
      let assert Error(jevelin.InvalidResponse(_)) =
        jevelin.decode_response(q, jevelin.HttpResponse(200, [], body))
        as "malformed response rejected"
    },
  )
}

pub fn homogeneous_batches_preserve_request_order_test() {
  let q = question.noul(Text("?"))
  let questions =
    batch.all([batch.question("b", q), batch.question("a", q)])
    |> batch.map(fn(ps) { list.map(ps, probability.value) })
  let assert Ok(request) = jevelin.evaluate(Text(""), questions)
    as "valid batch"
  let reply =
    jevelin.HttpResponse(
      200,
      [],
      "{\"model\":\"m\",\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":0},\"b\":{\"type\":\"noul\",\"noul\":1}},\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}",
    )
  let assert Ok(output) = jevelin.decode_response(request, reply)
    as "ordered results"
  assert output.answers == [1.0, 0.0]
}

pub fn model_listing_and_transport_error_identity_test() {
  let request = jevelin.models()
  assert jevelin.http_request(request)
    == jevelin.HttpRequest(
      jevelin.Get,
      "/v1/models",
      [#("accept", "application/json")],
      "",
    )
  let response =
    jevelin.HttpResponse(
      200,
      [],
      "{\"models\":[{\"name\":\"jev-latest\",\"description\":\"Stable\",\"release_date\":\"2026-09-15\"}]}",
    )
  assert jevelin.send(request, fn(_) { Ok(response) })
    == Ok([jevelin.Model("jev-latest", "Stable", "2026-09-15")])
  assert jevelin.send(request, fn(_) { Error(#("timeout", 5000)) })
    == Error(jevelin.TransportFailed(#("timeout", 5000)))
}

pub fn http_errors_preserve_body_status_and_retry_headers_test() {
  list.each([401, 422, 429, 529, 302, 204], fn(status) {
    let response =
      jevelin.HttpResponse(
        status,
        [
          #("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT"),
          #("retry-after-ms", "1250"),
        ],
        "upstream body, possibly not JSON",
      )
    assert jevelin.send(jevelin.models(), fn(_) { Ok(response) })
      == Error(jevelin.ResponseFailed(jevelin.HttpFailure(response)))
    assert jevelin.header(response, "RETRY-AFTER")
      == Some("Wed, 21 Oct 2026 07:28:00 GMT")
    assert jevelin.header(response, "retry-after-ms") == Some("1250")
    assert jevelin.header(response, "missing") == None
  })
  assert jevelin.retryable_status(529)
  assert jevelin.retryable_status(429)
  assert !jevelin.retryable_status(401)
  assert !jevelin.retryable_status(422)
  assert !jevelin.retryable_status(600)
}

pub fn unknown_metadata_does_not_break_forward_compatibility_test() {
  let answer = "{\"type\":\"noul\",\"noul\":0.7,\"future_metadata\":{\"x\":1}}"
  let decoded =
    jevelin.decode_response(
      prepared(question.noul(Text("?"))),
      response(answer),
    )
  assert result.is_ok(decoded)
}

pub fn optional_instructions_can_be_omitted_without_losing_answer_type_test() {
  let q = question.noul(Text("")) |> question.without_instructions
  let assert Ok(fields) =
    json.parse(
      question.encode(q) |> json.to_string,
      decode.dict(decode.string, decode.dynamic),
    )
    as "question object"
  assert !dict.has_key(fields, "instructions")
  let assert Ok(output) =
    jevelin.decode_response(
      prepared(q),
      response("{\"type\":\"noul\",\"noul\":0.7}"),
    )
    as "decoder preserved"
  assert probability.value(output.answers) == 0.7
}

pub fn oversized_integer_fields_return_errors_instead_of_crashing_test() {
  assert_oversized_rejected(
    question.noul(Text("?")),
    "{\"type\":\"noul\",\"noul\":NUMBER}",
  )
  assert_oversized_rejected(
    route_question(),
    "{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":NUMBER,\"probabilities\":{\"review\":0.9,\"build\":0.1}}",
  )
  assert_oversized_rejected(
    route_question(),
    "{\"type\":\"choice\",\"choice\":\"review\",\"confidence\":0.9,\"probabilities\":{\"review\":NUMBER,\"build\":0.1}}",
  )
  assert_oversized_rejected(
    score_question(),
    "{\"type\":\"score\",\"score\":NUMBER,\"confidence\":0.5,\"legend\":{\"0\":\"a\",\"1\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
  )
  assert_oversized_rejected(
    score_question(),
    "{\"type\":\"score\",\"score\":0.5,\"confidence\":NUMBER,\"legend\":{\"0\":\"a\",\"1\":\"b\"},\"probabilities\":{\"0\":0.5,\"1\":0.5}}",
  )
  assert_oversized_rejected(
    score_question(),
    "{\"type\":\"score\",\"score\":0.5,\"confidence\":0.5,\"legend\":{\"0\":\"a\",\"1\":\"b\"},\"probabilities\":{\"0\":NUMBER,\"1\":0.5}}",
  )
}

fn assert_oversized_rejected(q: question.Question(a), template: String) -> Nil {
  let huge = string.repeat("9", 400)
  list.each([huge, "-" <> huge], fn(number) {
    let body = string.replace(template, "NUMBER", number)
    let assert Error(jevelin.InvalidResponse(_)) =
      jevelin.decode_response(prepared(q), response(body))
      as "oversized integer rejected without float conversion"
    Nil
  })
}
