## Reconstruct complete captured games through the unchanged production simulator.
## No provider, player process, credentials, or synthetic receipt authority is used.
import std/[json, os, strutils]
import fruit_market/[sim, llm, prompts, training_capture]

if paramCount() == 1 and paramStr(1) == "--families":
  for seed in 0 .. 255:
    var config = defaultGameConfig()
    config.seed = seed
    let game = initSim(config)
    echo $(%*{"seed": seed, "family": game.physicalFamily(),
      "farms": game.farmTypesOf(), "physical": game.configJson()})
  quit(0)

if paramCount() != 2:
  quit("usage: verify_native_capture CONFIG.json TRAJECTORY.jsonl | --families", 1)
let nativeConfig = parseFile(paramStr(1))
var config = defaultGameConfig()
config.update($nativeConfig)
var names: seq[string]
for player in config.players: names.add(player.name)
var game = initSim(config, names)
let selection = promptSelection(nativeConfig)
var records: seq[JsonNode]
for line in lines(paramStr(2)):
  if line.len > 0: records.add(parseJson(line))
doAssert records.len > 1
let summary = records[^1]
doAssert summary["event_type"].getStr() == "episode"
doAssert summary["seed_family"].getStr() == game.physicalFamily()
var row = 0
var calls = 0
while not game.done:
  var orders: array[Seats, Order]
  for seat in 0 ..< Seats:
    doAssert row < records.high
    let decision = records[row]
    inc row
    doAssert decision["seat"].getStr() == $seat
    var observation = copy(decision["observation"])
    let operatorPolicy = observation["operator_policy"].getStr()
    observation.delete("prompt_attempts")
    observation.delete("operator_policy")
    doAssert observation == game.observationJson(seat), "private native view differs"
    var source = osScripted
    for attempt in decision["attempts"]:
      case attempt["origin"].getStr()
      of "model":
        inc calls
        let system = game.systemPrompt(seat, selection)
        var user = game.userPrompt(seat, operatorPolicy)
        let retried = attempt["attempt_id"].getStr().endsWith("-1")
        if retried: user.add(RetryHint)
        let request = attempt["request"]
        doAssert request["system"].getStr() == system
        doAssert request["messages"] == %*[{"role": "user", "content": user}]
        doAssert request["max_tokens"].getInt() == max(1000, config.maxOutputTokens)
        doAssert attempt["prompt"] == %*[
          {"role": "system", "content": system}, {"role": "user", "content": user}]
        source = if retried: osRetry else: osLlm
      of "fallback": source = osFallback
      of "unknown": source = osExternal
      of "teacher": source = osScripted
      else: doAssert false, "unrecognized native action origin"
    orders[seat] = parseOrder(decision["executed_action"], game, seat)
    orders[seat].source = source
  game.setRoundOrders(orders)
  game.runRound()
doAssert row == records.high, "unexpected trailing decisions"
doAssert summary["outcome"] == game.resultsJson(), "native terminal outcome differs"
echo $(%*{"native_decisions": row, "native_calls": calls,
  "family": game.physicalFamily(), "reason": game.reason,
  "scores": game.resultsJson()["scores"]})
