## Jev ranks ordinary standing orders from one seat's market observation.

import std/[json, os, strutils]
import curly

proc chooseOrder*(observation: JsonNode): JsonNode =
  let mine = observation["you"]["farmType"].getStr()
  let crave = observation["you"]["craves"].getStr()
  let ownStock = observation["you"][(if mine == "apple": "apples"
    else: "bananas")].getInt()
  let round = observation["round"].getInt()
  let stallNames = ["north", "east", "south", "west"]
  let rendezvous = stallNames[(round - 1) div 2 mod stallNames.len]
  let eat = if observation["you"]["hunger"].getInt() <= 45:
    "any" else: "crave"
  let giveN = if mine == "apple": 3 else: 2
  let wantN = if mine == "apple": 2 else: 3
  let bookOffer = %*{
    "give": {"fruit": mine, "n": giveN},
    "want": {"fruit": crave, "n": wantN}
  }
  var actions = newJObject()
  actions["harvest"] = %*{
    "job": "harvest", "fruit": mine, "eat": eat, "offer": bookOffer}
  for stall in stallNames:
    actions["market_" & stall] = %*{
      "job": "market", "stall": stall, "eat": eat, "offer": bookOffer}
  actions["trek"] = %*{
    "job": "trek", "fruit": crave, "eat": "crave", "offer": newJNull()}
  actions["rest"] = %*{"job": "rest", "eat": "any"}

  ## Visible offers can be mirrored exactly. The game will still check
  ## funding, distance, and the one-trade-per-round rule when it resolves.
  for other in observation["view"]["cogs"]:
    let offer = other["offer"]
    if offer.kind != JObject or offer["want"]["fruit"].getStr() != mine or
        offer["want"]["n"].getInt() > ownStock or
        offer["unfunded"].getBool():
      continue
    let mirror = %*{
      "give": offer["want"], "want": offer["give"]}
    actions["mirror_" & $other["slot"].getInt()] = %*{
      "job": "market", "stall": rendezvous, "eat": eat,
      "offer": mirror}

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Fruit Market Jev has no model transport")

  var criteria = newJObject()
  for name, order in actions.pairs:
    let consequence =
      if name == "harvest":
        "Gather the fruit you grow; trade stock and food become available. "
      elif name.startsWith("market_"):
        "Meet other traders at a stall and post the standard book price. "
      elif name.startsWith("mirror_"):
        "Post the exact mirror of a visible funded offer at the round's " &
          "rendezvous stall; trade only clears within range. "
      elif name == "trek":
        "Cross rivers to self-supply the fruit you crave, paying travel cost. "
      else:
        "Recover stamina without gathering or moving to a counterparty. "
    criteria[name] = %(consequence & $order)
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are one Fruit Market player. You score 5 for eating the " &
      "fruit you crave and 1 for your own fruit. Exact mirrored, funded " &
      "offers trade only when players are within range. The offer and " &
      "stall are the only signals to other players; speech is spectator " &
      "only. Choose a complete order for this round from your seat-private " &
      "observation:\n" & $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the order most likely to improve your final score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "fruit-market Jev player: round ", round, " choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = %*{"type": "order", "round": round, "order": actions[selected]}
