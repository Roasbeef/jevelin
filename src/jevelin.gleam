//// Jevelin prepares Jev requests and decodes answers into caller-owned types.
//// The library performs no I/O. A transport function owns credentials, network
//// policy, timeouts, cancellation, and retries. The same request can therefore
//// run through a normal HTTP client or a sandbox's brokered HTTP capability.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import jevelin/batch.{type Batch}
import jevelin/content.{type Content}
import jevelin/internal/wire

/// The official API origin. Request paths are relative to this origin.
pub const origin = "https://api.typesafe.ai"

/// The provider's moving stable alias. Pin a version for repeatable evaluations.
pub const latest = "jev-latest"

/// Methods used by the two supported endpoints.
pub type Method {
  /// Lists available models.
  Get

  /// Evaluates a batch of independent questions.
  Post
}

/// Transport-neutral HTTP data. Authentication is supplied by the transport.
pub type HttpRequest {
  HttpRequest(
    /// The endpoint's method.
    method: Method,
    /// A path relative to origin, with no credentials or user-controlled URL.
    path: String,
    /// Content negotiation headers only.
    headers: List(#(String, String)),
    /// UTF-8 JSON, or an empty string for GET.
    body: String,
  )
}

/// A fully received HTTP response. Transport owns the response-size limit.
pub type HttpResponse {
  HttpResponse(
    /// The HTTP status code.
    status: Int,
    /// Response headers, including any retry guidance.
    headers: List(#(String, String)),
    /// UTF-8 response body, retained verbatim on HTTP errors.
    body: String,
  )
}

/// A request and its response decoder cannot be accidentally mixed up.
pub opaque type Request(answer) {
  Request(http: HttpRequest, decoder: decode.Decoder(answer))
}

/// A local request error, before any transport is invoked.
pub type BuildError {
  /// The model name was empty or whitespace-only.
  EmptyModel

  /// The batch was empty or reused a question name.
  InvalidBatch(reason: batch.BuildError)
}

/// Decoding distinguishes HTTP failure from malformed successful responses.
pub type ResponseError {
  /// Non-200 responses preserve status, headers, and the original error body.
  HttpFailure(response: HttpResponse)

  /// JSON syntax, shape, domain, or probability validation failed.
  InvalidResponse(reason: json.DecodeError)
}

/// A transport's own error type is preserved without string conversion.
pub type Error(transport_error) {
  /// The transport failed before a complete response was received.
  TransportFailed(reason: transport_error)

  /// The service rejected the request or returned an invalid answer.
  ResponseFailed(reason: ResponseError)
}

/// Reported tokens; free output still has a token count.
pub type Usage {
  Usage(
    /// Nonnegative billable input token count.
    input_tokens: Int,
    /// Nonnegative output token count.
    output_tokens: Int,
  )
}

/// Answers together with model provenance and usage.
pub type Evaluation(answer) {
  Evaluation(
    /// The model that actually answered, which may resolve an alias.
    model: String,
    /// The batch's statically known output type.
    answers: answer,
    /// Provider-reported token accounting.
    usage: Usage,
  )
}

/// One model returned by the account's model catalogue.
pub type Model {
  Model(
    /// A model name or alias accepted by the evaluation endpoint.
    name: String,
    /// The provider's description.
    description: String,
    /// The provider's date string, usually YYYY-MM-DD.
    release_date: String,
  )
}

/// Prepares an evaluation using the stable model alias.
///
/// ## Examples
///
/// ```gleam
/// jevelin.evaluate(content.Text("The build failed"), questions)
/// ```
pub fn evaluate(
  state: Content,
  questions: Batch(a),
) -> Result(Request(Evaluation(a)), BuildError) {
  evaluate_with_model(state, latest, questions)
}

/// Prepares an evaluation using an explicit model or version.
///
/// ## Examples
///
/// ```gleam
/// jevelin.evaluate_with_model(state, "jev-1.13.0", questions)
/// ```
pub fn evaluate_with_model(
  state: Content,
  model: String,
  questions: Batch(a),
) -> Result(Request(Evaluation(a)), BuildError) {
  use _ <- result.try(case string.trim(model) {
    "" -> Error(EmptyModel)
    _ -> Ok(Nil)
  })
  use encoded <- result.try(
    batch.encode(questions) |> result.map_error(InvalidBatch),
  )
  let body =
    json.object([
      #("state", content.encode(state)),
      #("model", json.string(model)),
      #("questions", encoded),
    ])
    |> json.to_string
  let decoder = {
    use model <- decode.field("model", decode.string)
    use answers <- decode.field("answers", batch.decoder(questions))
    use usage <- decode.field("usage", usage_decoder())
    decode.success(Evaluation(model:, answers:, usage:))
  }
  Ok(Request(
    http: HttpRequest(
      Post,
      "/v1/systemone",
      [
        #("content-type", "application/json"),
        #("accept", "application/json"),
      ],
      body,
    ),
    decoder:,
  ))
}

/// Prepares the authenticated model-list endpoint.
///
/// ## Examples
///
/// ```gleam
/// jevelin.models() |> jevelin.send(transport)
/// ```
pub fn models() -> Request(List(Model)) {
  let model = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use release_date <- decode.field("release_date", decode.string)
    decode.success(Model(name:, description:, release_date:))
  }
  Request(
    http: HttpRequest(Get, "/v1/models", [#("accept", "application/json")], ""),
    decoder: decode.at(["models"], decode.list(model)),
  )
}

/// Extracts the HTTP data for an asynchronous or capability-based transport.
/// Keep the original typed request to decode its eventual response.
///
/// ## Examples
///
/// ```gleam
/// jevelin.http_request(jevelin.models()).path // => "/v1/models"
/// ```
pub fn http_request(request: Request(a)) -> HttpRequest {
  request.http
}

/// Validates an HTTP response against the original request's answer contract.
///
/// ## Examples
///
/// ```gleam
/// jevelin.decode_response(jevelin.models(), response)
/// ```
pub fn decode_response(
  request: Request(a),
  response: HttpResponse,
) -> Result(a, ResponseError) {
  case response.status {
    200 ->
      json.parse(response.body, request.decoder)
      |> result.map_error(InvalidResponse)
    _ -> Error(HttpFailure(response))
  }
}

/// Executes exactly one attempt through caller-owned transport.
/// No hidden retries, sleeping, credential lookup, or logging occurs here.
///
/// ## Examples
///
/// ```gleam
/// jevelin.models() |> jevelin.send(fn(request) {
///   my_http_client(request)
/// })
/// ```
pub fn send(
  request: Request(a),
  transport: fn(HttpRequest) -> Result(HttpResponse, e),
) -> Result(a, Error(e)) {
  use response <- result.try(
    transport(request.http) |> result.map_error(TransportFailed),
  )
  decode_response(request, response) |> result.map_error(ResponseFailed)
}

/// Finds a response header case-insensitively, preserving its original value.
/// This supports both Retry-After dates and retry-after-ms without owning time.
///
/// ## Examples
///
/// ```gleam
/// jevelin.header(response, "retry-after") // => Some("2")
/// ```
pub fn header(response: HttpResponse, name: String) -> Option(String) {
  let name = string.lowercase(name)
  list.find(response.headers, fn(pair) { string.lowercase(pair.0) == name })
  |> result.map(fn(pair) { pair.1 })
  |> option.from_result
}

/// Identifies statuses retried by the official SDKs. The caller still decides
/// whether another attempt fits its deadline and request budget.
///
/// ## Examples
///
/// ```gleam
/// jevelin.retryable_status(529) // => True
/// jevelin.retryable_status(401) // => False
/// ```
pub fn retryable_status(status: Int) -> Bool {
  status == 408 || status == 429 || { status >= 500 && status <= 599 }
}

fn usage_decoder() -> decode.Decoder(Usage) {
  let count =
    wire.checked(decode.int, "a nonnegative token count", fn(n) { n >= 0 })
  use input_tokens <- decode.field("input_tokens", count)
  use output_tokens <- decode.field("output_tokens", count)
  decode.success(Usage(input_tokens:, output_tokens:))
}
