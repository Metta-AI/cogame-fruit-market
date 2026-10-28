## Private native evidence. Spectator/replay formats and gameplay are unchanged.
import std/[base64, json, options, os, strutils, tables, unicode]
import crunchy, curly
import ./decision_trajectory, ./sim
export decision_trajectory, options

type
  CapturedDecision = object
    observation: JsonNode
    attempts: seq[DecisionAttempt]
  RuntimeCapture* = ref object
    trajectory: DecisionTrajectory
    turn: seq[CapturedDecision]

proc physicalFamily*(sim: Sim): string =
  ## Randomness is consumed only by the initial farm shuffle. Alias seeds with
  ## identical farms/rules are the same physical task, regardless of wording.
  var physical = sim.configJson()
  physical.delete("variant")
  physical["farms"] = newJArray()
  for cog in sim.cogs: physical["farms"].add(%($cog.farm))
  "fruit-market-physical-v1-" & sha256($physical).toHex.toLowerAscii()

proc newRuntimeCapture*(sim: Sim): RuntimeCapture =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  RuntimeCapture(trajectory: newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    sim.physicalFamily(), "fruit-market", getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION")))

proc beginTurn*(capture: RuntimeCapture, observations: seq[JsonNode]) =
  if capture == nil: return
  capture.turn = newSeq[CapturedDecision](observations.len)
  for seat, observation in observations:
    capture.turn[seat].observation = copy(observation)
    capture.turn[seat].observation["prompt_attempts"] = newJArray()

proc modelAttempt*(identity, policy, model, body: string,
    response: Response, error: string, latency: int): DecisionAttempt =
  result = newDecisionAttempt(identity, policy, aoModel)
  result.model = some(model)
  let request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": request["system"]},
    {"role": "user", "content": request["messages"][0]["content"]}]
  result.request = copy(request)
  result.decoder = %*{"max_tokens": request["max_tokens"]}
  for key in ["temperature", "top_p", "top_k", "output_config"]:
    if request.hasKey(key): result.decoder[key] = request[key]
  result.latencyMs = some(float(latency))
  if response.body.validateUtf8() == -1: result.rawResponse = %response.body
  result.responseBodyB64 = some(encode(response.body))
  result.responseComplete = some(error.len == 0)
  if response.code in 100 .. 599: result.httpStatus = some(response.code)
  var headers = initTable[string, string]()
  for (key, value) in response.headers: headers[key] = value
  result.responseHeaders = some(headers)
  if response.headers.contains("X-Softmax-Llm-Call-Id"):
    result.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
  for key in ["request-id", "x-request-id"]:
    if response.headers.contains(key):
      result.providerRequestId = some(response.headers[key])
      break
  if error.len > 0: result.rejectionReason = some(error)
  try:
    let payload = parseJson(response.body)
    if payload{"model"}.getStr().len > 0: result.model = some(payload["model"].getStr())
    if payload{"stop_reason"}.getStr().len > 0:
      result.stopReason = some(payload["stop_reason"].getStr())
    if payload.hasKey("usage"):
      if payload["usage"].hasKey("input_tokens"):
        result.inputTokens = some(payload["usage"]["input_tokens"].getInt())
      if payload["usage"].hasKey("output_tokens"):
        result.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  except CatchableError: discard # Preserve original received bytes on malformed/error replies.

proc recordAttempt*(capture: RuntimeCapture, seat: int, evidence: DecisionAttempt,
    promptMetadata: JsonNode) =
  if capture == nil: return
  capture.turn[seat].attempts.add(evidence)
  capture.turn[seat].observation["prompt_attempts"].add(%*{
    "attempt_id": evidence.attemptId, "prompt_template": promptMetadata})

proc applied*(capture: RuntimeCapture, seat, tick: int, action: JsonNode,
    origin: AttemptOrigin, policy: string) =
  if capture == nil: return
  var attempts = capture.turn[seat].attempts
  var selected = none(string)
  var status = asAccepted
  if origin == aoModel:
    for attempt in attempts:
      if attempt.accepted and attempt.parsedAction == action:
        selected = some(attempt.attemptId)
    # Normalization is a training-target rejection, not a substituted baseline.
    if selected.isNone: status = asRejected
  else:
    var actual = newDecisionAttempt($tick & "-" & $seat & "-engine", policy, origin)
    actual.parsedAction = copy(action)
    actual.accepted = true
    selected = some(actual.attemptId)
    attempts.add(actual)
    if origin == aoFallback: status = asFallback
  capture.trajectory.recordDecision($tick & "-" & $seat, $seat,
    capture.turn[seat].observation, attempts, selected, action, status,
    fallbackOrigin = (if origin == aoFallback: some(policy) else: none(string)))

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode) =
  if capture == nil: return
  let status = case outcome{"reason"}.getStr()
    of "complete": esCompleted
    of "deadline": esTruncated
    else: esFailed
  capture.trajectory.finish(status, outcome, outcome{"scores"})
  capture.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
