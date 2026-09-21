//// This example is included verbatim in README.md and compiled on both targets.

import gleam/option.{None, Some}
import jevelin
import jevelin/batch
import jevelin/content.{Text}
import jevelin/probability.{type Probability}
import jevelin/question.{type Choice}

type Workflow {
  Review
  Implement
}

type Signals {
  Signals(workflow: Choice(Workflow), needs_clarification: Probability)
}

pub fn typed_workflow_test() {
  // Literal criteria are checked once, before preparing any HTTP request.
  let assert Ok(workflow) =
    question.choice(Text("Which workflow fits?"), [
      question.Alternative(
        "review",
        Review,
        Some(Text("Inspect existing code")),
      ),
      question.Alternative("implement", Implement, None),
    ])
    as "valid workflow alternatives"

  let questions =
    batch.map2(
      batch.question("workflow", workflow),
      batch.question(
        "clarify",
        question.noul(Text("Is essential information missing?")),
      ),
      Signals,
    )
  let assert Ok(request) =
    jevelin.evaluate_with_model(
      Text("Review this diff"),
      "jev-1.13.0",
      questions,
    )
    as "valid request"

  // Replace fixture_transport with an HTTP adapter in your application.
  let assert Ok(evaluation) = jevelin.send(request, fixture_transport)
    as "valid response"
  assert evaluation.answers.workflow.selected == Review
  assert probability.value(evaluation.answers.needs_clarification) == 0.1
}

fn fixture_transport(
  request: jevelin.HttpRequest,
) -> Result(jevelin.HttpResponse, Nil) {
  assert request.method == jevelin.Post
  assert request.path == "/v1/systemone"
  Ok(jevelin.HttpResponse(
    200,
    [],
    "{
    \"model\": \"jev-1.13.0\",
    \"answers\": {
      \"workflow\": {
        \"type\": \"choice\", \"choice\": \"review\", \"confidence\": 0.8,
        \"probabilities\": {\"review\": 0.9, \"implement\": 0.1}
      },
      \"clarify\": {\"type\": \"noul\", \"noul\": 0.1}
    },
    \"usage\": {\"input_tokens\": 100, \"output_tokens\": 20}
  }",
  ))
}
