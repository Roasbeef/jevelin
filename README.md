# Jevelin

Typed [Jev](https://docs.typesafe.ai/introduction) decisions for Gleam.
The name combines Jev and javelin.

A Choice returns your own domain type. Independent questions combine into a
record with `batch.map2`, or into an ordered list with `batch.all`. Every
prepared request retains its matching decoder, so a response cannot introduce
an unknown Choice label or silently change an answer's type.

Jevelin is a **sans-I/O** library: it prepares HTTP requests and decodes
responses, while your transport owns credentials, timeouts, cancellation,
response-size limits, and retries. It compiles to Erlang and JavaScript, with
only `gleam_stdlib` and `gleam_json` as runtime dependencies.

## Try it

This repository is not published on Hex. Clone it and run the examples and tests:

```sh
git clone git@github.com:roasbeef/jevelin.git
cd jevelin
gleam deps download
gleam test
gleam test --target javascript
```

For local development in another Gleam project:

```toml
[dependencies]
jevelin = { path = "../jevelin" }
```

Requires Gleam 1.18 or newer. CI runs on Erlang/OTP 29 and Node.js 22.

## Typed choices and mixed batches

This complete example is also [compiled as a test](test/example_test.gleam).
The assertions check fixed example data. In application code, propagate
constructor and request errors with `result.try`.

```gleam
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
```

`evaluation.answers.workflow.selected` has type `Workflow`, so a `case` over
it is exhaustive. The returned probabilities are still available for ranking
and confidence policies. A typed answer can still be factually wrong.

For a score, use `question.score(instructions, levels)` with two to ten ordered
`Content` values. Its `Score.value` is a fractional expected index. Noul returns
a `Probability` directly, without a separate confidence field. Use
`probability.value` when comparing or combining numeric signals.

`Content` supports `Text`, `Object`, and `Array`. Choice descriptions are
`Option(Content)`; `None` leaves a label undescribed. All builders are pure,
and invalid question counts or duplicate labels are returned as errors.

## Connect a transport

`jevelin.send(request, transport)` calls:

```gleam
fn(jevelin.HttpRequest) -> Result(jevelin.HttpResponse, YourTransportError)
```

Join `request.path` to `jevelin.origin`, map `Get` or `Post` to your client's
method, and send the supplied headers and body. Attach the bearer credential
there. Return the complete status, headers, and UTF-8 body as `HttpResponse`.
There is no credential field in the prepared request and no implicit logging.

For asynchronous clients, call `jevelin.http_request(request)` and pass the
returned response to `jevelin.decode_response(request, response)` later.
`jevelin.models()` prepares the model-list endpoint through the same transport.

`TransportFailed` retains your transport's error type. `ResponseFailed` wraps
either an HTTP error with its original response or a JSON/domain decoding
error. `retryable_status` and `header` expose retry guidance without sleeping
or spending another request automatically.

## Loom extensions

The pure request/response boundary is designed for a `cap/net` adapter. The
extension can map `HttpRequest` to a capability request, while the broker
injects the Authorization header. Jevelin itself does not need network or
credential authority.

This repository does **not** install an extension or change Loom's dependency
allowlist. Admitting or packaging these pure modules under Loom's vetted
extension rules is a separate integration step. HTTP response bytes must be
converted to UTF-8, with decoding failures returned as transport errors.

## API evidence and validation

[API.md](docs/API.md) records the source revisions, request and response
contracts, upstream documentation disagreements, and local validation policy.
The [OpenAPI snapshot](docs/upstream/openapi.json) was fetched from the official
endpoint on September 21, 2026.

The suite covers mixed and homogeneous batches, request-bound label and key
validation, structured score legends, malformed responses, HTTP failures,
transport error identity, and 1,201 generated probability boundary cases.
It also rejects 400-digit positive and negative numbers without crashing the
Erlang decoder. The README example is compiled on both targets.

Authenticated live evaluations are not part of the initial verification;
no API key is needed to run the suite.

```sh
gleam format --check src test
gleam build --warnings-as-errors
gleam test
gleam build --target javascript --warnings-as-errors
gleam test --target javascript
gleam docs build
```
