## Persistent JSONL bridge for Metta RL and native PufferLib training.
## nim c -d:release --path:src -o:fruit-market-train-bridge tools/train_bridge.nim

import std/[json, os]
import fruit_market/[sim_types, sim_config, sim_state, scripted, sim, llm]

const OperatorPrompt = "Maximize your own score by farming, trading, and eating fruit you crave."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc offerJson(offer: Offer): JsonNode =
  %*{"give": {"fruit": $offer.giveFruit, "n": offer.giveN},
    "want": {"fruit": $offer.wantFruit, "n": offer.wantN}}

proc appendOffer(values: var JsonNode, offer: JsonNode) =
  if offer.kind == JNull:
    for field in 0 ..< 6:
      values.add(%0)
  else:
    values.add(%1)
    values.add(%(if offer["give"]["fruit"].getStr() == "apple": 0 else: 1))
    values.add(offer["give"]["n"])
    values.add(%(if offer["want"]["fruit"].getStr() == "apple": 0 else: 1))
    values.add(offer["want"]["n"])
    values.add(%(if offer["unfunded"].getBool(): 1 else: 0))

proc decision(game: Sim, seat, id: int): JsonNode =
  %*{
    "kind": "decision", "game": "fruit-market", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.roundOf(),
    "semantic_view": game.observationJson(seat),
    "inbox": [],
    "messages": [
      {"role": "system", "content": game.systemPrompt(seat)},
      {"role": "user", "content": game.userPrompt(seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object",
      "required": ["job", "fruit", "stall", "eat", "offer"],
      "properties": {
        "job": {"type": "string", "enum": ["harvest", "market", "trek", "rest"]},
        "fruit": {"type": "string", "enum": ["default", "apple", "banana"]},
        "stall": {"type": "string", "enum": ["default", "north", "east", "south", "west"]},
        "eat": {"type": "string", "enum": ["crave", "any", "none"]},
        "offer": {"oneOf": [
          {"type": "string", "enum": ["keep", "withdraw"]},
          {"type": "object", "required": ["give", "want"],
            "properties": {
              "give": {"type": "object", "required": ["fruit", "n"]},
              "want": {"type": "object", "required": ["fruit", "n"]}
            }}
        ]}
      }},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, seat, id: int): JsonNode =
  let view = game.observationJson(seat)
  let you = view["you"]
  var values = newJArray()
  for variant in ["open-market", "concentric-rivers", "deep-rivers",
      "lean-harvest"]:
    values.add(%(if game.config.variantId() == variant: 1 else: 0))
  for slot in 0 ..< Seats:
    values.add(%(if slot == seat: 1 else: 0))
  for key in ["round", "rounds", "tick"]:
    values.add(view[key])
  values.add(you["cell"][0])
  values.add(you["cell"][1])
  for key in ["farmType", "craves"]:
    values.add(%(if you[key].getStr() == "apple": 0 else: 1))
  for key in ["apples", "bananas", "hunger", "stamina", "score",
      "tradesThisEpisode"]:
    values.add(you[key])
  values.add(%(if you["exhausted"].getBool(): 1 else: 0))
  values.appendOffer(you["offer"])
  for stall in view["stalls"]:
    values.add(stall["cell"][0])
    values.add(stall["cell"][1])
    values.add(stall["dist"])
  for slot in 0 ..< Seats:
    if slot == seat:
      continue
    var peer = newJNull()
    for current in view["view"]["cogs"]:
      if current["slot"].getInt() == slot:
        peer = current
    if peer.kind == JNull:
      for field in 0 ..< 11:
        values.add(%0)
    else:
      values.add(%1)
      values.add(peer["cell"][0])
      values.add(peer["cell"][1])
      values.add(peer["dist"])
      values.add(%(if peer["mirrorsYou"].getBool(): 1 else: 0))
      values.appendOffer(peer["offer"])
  for row in view["view"]["map"]:
    let cells = row.getStr()
    doAssert cells.len == 2 * game.config.viewRadius + 1
    for cell in cells:
      values.add(%ord(cell))
  doAssert view["view"]["map"].len == 2 * game.config.viewRadius + 1
  let history = view["history"]
  for offset in 0 ..< 4:
    if offset >= history.len:
      for field in 0 ..< 9:
        values.add(%0)
    else:
      let row = history[history.len - 1 - offset]
      for key in ["round", "score", "hunger", "stamina", "trades",
          "harvested", "eaten", "crossings", "marketRate"]:
        values.add(row[key])
  var offers = %*["keep", "withdraw"]
  for give in Fruit:
    let want = if give == fApple: fBanana else: fApple
    for giveN in OfferMin .. game.config.offerMax:
      for wantN in OfferMin .. game.config.offerMax:
        offers.add(offerJson(Offer(active: true,
          giveFruit: give, giveN: giveN,
          wantFruit: want, wantN: wantN)))
  %*{"decision_id": id, "values": values, "action_heads": [
    {"name": "job", "choices": ["harvest", "market", "trek", "rest"]},
    {"name": "fruit", "choices": ["default", "apple", "banana"]},
    {"name": "stall", "choices": ["default", "north", "east", "south", "west"]},
    {"name": "eat", "choices": ["crave", "any", "none"]},
    {"name": "offer", "choices": offers}
  ]}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: fruit-market-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: "open-market"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var orders: array[Seats, Order]
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      var tokens = newJArray()
      for slot in 0 ..< Seats:
        tokens.add(%("t" & $slot))
      runtimeConfig["tokens"] = tokens
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSim(config)
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.done
      let order = scriptedOrder(game, seat, skHauler)
      var offer: JsonNode = %"keep"
      if order.hasOfferKey:
        offer = if order.withdraw: %"withdraw" else: offerJson(order.offer)
      let action = %*{
        "job": $order.job,
        "fruit": (if order.hasFruit: $order.fruit else: "default"),
        "stall": (if order.hasStall: $order.stall else: "default"),
        "eat": $order.eat,
        "offer": offer
      }
      response = %*{"response": $action}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      var payload = %*{"job": action["job"], "eat": action["eat"]}
      for field in ["fruit", "stall"]:
        if action[field].getStr() != "default":
          payload[field] = action[field]
      if action["offer"].kind == JObject:
        payload["offer"] = action["offer"]
      elif action["offer"].getStr() == "withdraw":
        payload["offer"] = newJNull()
      else:
        doAssert action["offer"].getStr() == "keep"
      orders[seat] = parseOrder(payload, game, seat)
      inc id
      var observation: JsonNode
      if seat == Seats - 1:
        game.setRoundOrders(orders)
        game.runRound()
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< Seats:
            scores[$slot] = outcome["scores"][slot]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          seat = 0
          observation = game.decision(seat, id)
      else:
        inc seat
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
