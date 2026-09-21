# Jev API contract

Verified against the public API and official SDKs on September 21, 2026.
Jevelin implements the two endpoints in the live OpenAPI document:

| Endpoint | Request | Response |
| --- | --- | --- |
| `POST /v1/systemone` | State, model, named independent questions | Named answers, resolved model, token usage |
| `GET /v1/models` | Authentication only | Model names, descriptions, release dates |

Sources:

- [Live OpenAPI](https://api.typesafe.ai/openapi.json), captured in [upstream/openapi.json](upstream/openapi.json).
- [HTTP reference](https://docs.typesafe.ai/api).
- [Models and limits](https://docs.typesafe.ai/models).
- [Python SDK at 2ce5c65](https://github.com/typesafe-ai/typesafe-sdk-python/tree/2ce5c65f13646cab6e6f782328194c9d85f3300a).
- [JavaScript SDK at 66880cc](https://github.com/typesafe-ai/typesafe-sdk-js/tree/66880ccded6cb642dc1809620c2b108c33730214).

The snapshot is an upstream reference artifact. The Gleam implementation is
handwritten and does not depend on either SDK.

## Questions and answers

`Content` accepts a string, JSON object, or JSON array at the top level.
Nested values are ordinary JSON. A state cannot be null, a number, or a boolean.
Choice descriptions can be absent, encoded as null. Noul criteria may omit
either or both sides. Instructions can be omitted with
`question.without_instructions`.

A Choice returns a requested label mapped to the application's own Gleam
value, confidence, and the distribution over all requested alternatives.
Labels are distinct, and results retain request order. Different labels may
map to equal application values; callers choosing that representation also
choose to lose the distinction between those labels.

A Score returns a fractional expected zero-based index, confidence, the
structured legend, and each level's probability. It is not an integer class
prediction. A Noul returns the probability of yes; it has no separate confidence
field. The library does not turn any probability into a boolean decision.

Questions in a batch are independent. `batch.map2` transforms decoded results;
it cannot make one question depend on another answer from the same request.
Dependent decisions require separate HTTP requests.

## Differences between upstream documents

The HTTP prose marks instructions required. OpenAPI and both SDKs permit
omission or null. Jevelin emits instructions by default and supports omission;
it does not need a second null representation for the same operation.

The HTTP prose describes score legend values as strings. OpenAPI permits
strings, objects, and arrays, and the JavaScript SDK preserves the rubric's
type. Jevelin supports all three shapes, including nested JSON values.

OpenAPI declares a score minimum of one level and no maximum; the SDKs reject
fewer than two, and the prose specifies two to ten. Jevelin follows the documented
usable range of two to ten. Choice has a prose limit of 255 alternatives that
is absent from OpenAPI. Jevelin enforces one to 255 and rejects duplicate labels.

## Validation policy

Every successful response must have the requested answer names and types.
Choice labels and probability-map keys must belong to the original question.
Score probabilities and legends must have exactly the requested level indexes.
All probabilities and confidence values must be in [0, 1], and scores must fall
within the requested rubric. Negative or missing token counts are rejected.
Extra metadata fields are ignored; extra or missing answers are errors.

Probability mass is accepted within an absolute tolerance of 0.001 around one.
That tolerance is Jevelin policy, not a precision guarantee from TypeSafe;
OpenAPI says the probabilities sum to approximately one. The library does not
recompute confidence, rewrite a selected choice, or round a fractional score.
It validates structure and bounds, not the truth of a model's judgment.

The JSON dependency parses JSON objects before domain decoding. Duplicate
keys in an incoming JSON object follow that parser's behavior; Jevelin does not
claim to detect duplicates in raw JSON. Duplicate names in outgoing batches
and Choice criteria are rejected before serialization.

## Transport and failures

Prepared requests contain an HTTP method, relative path, JSON body, and content
negotiation headers. The caller attaches `Authorization: Bearer <key>` at the
transport boundary. The library never reads environment variables, opens
sockets, logs bodies, or retains a configured credential.

`send` makes one attempt. A transport error retains the caller's error type.
A non-200 response retains its status, headers, and raw body, including HTML or
plain-text proxy errors. A malformed 200 response is a separate error with JSON
decode paths. The raw HTTP body can contain request content; callers control
whether and how to log it.

The API documents 401, 422, 429, and 529. `retryable_status` matches the official
SDK policy of 408, 429, and 500 through 599. It is advice, not a retry loop.
`header` retrieves Retry-After or retry-after-ms case-insensitively, leaving
HTTP-date parsing, backoff, jitter, cancellation, and total deadlines with the
transport owner. Transport must enforce response-size limits and validate
UTF-8 before producing `HttpResponse`.

There is no streaming endpoint. Token-window and rate limits are enforced by
the service; Jevelin does not estimate tokens using an unrelated tokenizer.
No authenticated live evaluation was performed during initial development.
The suite exercises the public wire examples, typed composition, malformed
responses, generated probability boundaries, and injected transport on both
Erlang and JavaScript.
