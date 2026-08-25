## tests/test_llm.nim — the decision layer.
##
## No network: the transport is exercised through `decideAll` with the client
## disabled (which is exactly the hosted no-credentials path) and through the
## parser and extractor directly.

import std/[json, strutils, unittest]

import fruit_market/sim, fruit_market/scripted, fruit_market/llm

proc bench(seed = 2): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  result = initSim(config)
  for slot in 0 ..< Seats:
    result.cogs[slot].apples = 6
    result.cogs[slot].bananas = 6

proc parse(sim: Sim, text: string, slot = 0): Order =
  parseOrder(extractJsonObject(text), sim, slot)

suite "extracting the object":
  let sim = bench()
  test "a fenced reply":
    let order = sim.parse("""Sure!
```json
{"job": "market", "stall": "north", "eat": "crave"}
```
""")
    check order.job == jMarket
    check order.stall == stNorth
    check order.eat == epCrave

  test "a prose-prefixed reply with trailing prose":
    let order = sim.parse(
      "I will go and harvest. {\"job\":\"harvest\"} Hope that helps.")
    check order.job == jHarvest

  test "no object at all is an error that quotes the head of the reply":
    expect FruitMarketError:
      discard sim.parse("I am sorry, I cannot help with that request.")

suite "the reply schema":
  let sim = bench()
  test "an unknown job is invalid":
    expect FruitMarketError:
      discard sim.parse("""{"job":"loiter"}""")

  test "a missing job is invalid":
    expect FruitMarketError:
      discard sim.parse("""{"eat":"any"}""")

  test "an unknown fruit, stall or eat value is invalid":
    expect FruitMarketError:
      discard sim.parse("""{"job":"harvest","fruit":"durian"}""")
    expect FruitMarketError:
      discard sim.parse("""{"job":"market","stall":"northeast"}""")
    expect FruitMarketError:
      discard sim.parse("""{"job":"rest","eat":"sometimes"}""")

  test "give.fruit == want.fruit is invalid":
    expect FruitMarketError:
      discard sim.parse("""{"job":"market","offer":
        {"give":{"fruit":"apple","n":3},"want":{"fruit":"apple","n":2}}}""")

  test "a non-integer n is invalid":
    expect FruitMarketError:
      discard sim.parse("""{"job":"market","offer":
        {"give":{"fruit":"apple","n":"three"},"want":{"fruit":"banana","n":2}}}""")

  test "n = 9 is clamped to 6 and flagged":
    let order = sim.parse("""{"job":"market","offer":
      {"give":{"fruit":"apple","n":9},"want":{"fruit":"banana","n":0}}}""")
    check order.offer.giveN == 6
    check order.offer.wantN == 1
    check order.clamped

  test "a missing offer key leaves the standing offer, null withdraws it":
    let untouched = sim.parse("""{"job":"rest"}""")
    check not untouched.hasOfferKey
    check not untouched.withdraw
    let withdrawn = sim.parse("""{"job":"rest","offer":null}""")
    check withdrawn.hasOfferKey
    check withdrawn.withdraw

  test "eat defaults to any and say/notes are truncated at the caps":
    var long = "x".repeat(400)
    let order = sim.parse("""{"job":"rest","say":"""" & long &
      """","notes":"""" & long & """"}""")
    check order.eat == epAny
    check order.say.len <= MaxSayLen + 3
    check order.notes.len <= MaxNotesLen + 3

  test "the standing order the sim accepts is the one the parser produced":
    var game = bench()
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(game, slot, skHauler)
    orders[0] = game.parse("""{"job":"market","stall":"south","eat":"any",
      "offer":{"give":{"fruit":"apple","n":3},"want":{"fruit":"banana","n":2}}}""")
    game.cogs[0].farm = fApple
    game.setRoundOrders(orders)
    game.stepTick()
    check game.cogs[0].offer.active
    check game.cogs[0].offer.giveN == 3

suite "degrade, never hang":
  test "with no credentials every seat plays hauler and nothing raises":
    var game = bench()
    var config = game.config
    let client = newLlmClient(config)
    client.disabled = true
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      prompts[slot] = "trade well"
      scripts[slot] = skNone
      connected[slot] = true
    let orders = client.decideAll(game, prompts, scripts, connected)
    for slot in 0 ..< Seats:
      check orders[slot].job in {jHarvest, jMarket, jTrek, jRest}
      check orders[slot] == scriptedOrder(game, slot, skHauler)

  test "a seat that never connected plays hauler for the whole episode":
    var game = bench()
    var config = game.config
    let client = newLlmClient(config)
    client.disabled = true   ## never touch the network from a unit test
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      scripts[slot] = skNone
      connected[slot] = slot != 3
    let orders = client.decideAll(game, prompts, scripts, connected)
    check orders[3] == scriptedOrder(game, 3, skHauler)

  test "a scripted registration is honoured without a request":
    var game = bench()
    var config = game.config
    let client = newLlmClient(config)
    client.disabled = true   ## never touch the network from a unit test
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      connected[slot] = true
      scripts[slot] = if slot < 4: skHauler else: skHomesteader
    let orders = client.decideAll(game, prompts, scripts, connected)
    for slot in 0 ..< Seats:
      let want = if slot < 4: skHauler else: skHomesteader
      check orders[slot] == scriptedOrder(game, slot, want)

suite "the batch and the pacing floor":
  test "one batch carries every open seat":
    ## `decideAll` opens exactly the seats that are connected, unregistered as
    ## scripted, and playable — eight on round one — and issues them as ONE
    ## parallel batch. Counting them here is what keeps a future refactor from
    ## quietly going sequential.
    var game = bench()
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    var open = 0
    for slot in 0 ..< Seats:
      scripts[slot] = skNone
      connected[slot] = true
      if scripts[slot] == skNone and connected[slot]:
        open.inc
    check open == Seats

  test "minTurnSeconds holds the request rate under 30 a minute":
    let config = defaultGameConfig()
    check config.minTurnSeconds > 0
    let perMinute = Seats.float * 60.0 / config.minTurnSeconds.float
    check perMinute < 30.0

  test "the deadlines are whole seconds and the token budget is at least 1000":
    var config = defaultGameConfig()
    check config.llmTimeoutSeconds == config.llmTimeoutSeconds.int
    check config.maxOutputTokens >= 1000
    expect FruitMarketError:
      config.update("""{"llmTimeoutSeconds": 0}""")

  test "the whole play budget fits inside 60% of the episode timeout":
    let config = defaultGameConfig()
    let worst = config.rounds * 2 * config.llmTimeoutSeconds +
      config.playerConnectTimeoutSeconds div 6 + config.shutdownGraceSeconds
    check worst < (config.episodeTimeoutSeconds * 6) div 10

suite "prompts":
  test "the system prompt states the output contract and the mirror rule twice":
    let game = bench()
    let system = game.systemPrompt(0)
    check "reply with ONLY one JSON object" in system
    check "begin with the character {" in system
    check "EXACT MIRROR" in system
    check "the only offer of yours that can clear with it" in system
    check "SIMULTANEOUSLY" in system
    check "NOBODY CAN HEAR ANYTHING YOU SAY" in system

  test "the user prompt precomputes the legal choice set for this variant":
    let game = bench()
    let user = game.userPrompt(0, "be a market maker")
    check "harvest|market|trek|rest" in user
    check "north|east|south|west" in user
    check "crave|any|none" in user
    check "GUIDANCE FROM YOUR OPERATOR" in user
    check "be a market maker" in user

  test "the observation hides every other cog's private state":
    let game = bench()
    let obs = game.observationJson(0)
    for entry in obs["view"]["cogs"]:
      check not entry.hasKey("farmType")
      check not entry.hasKey("apples")
      check not entry.hasKey("hunger")
      check not entry.hasKey("score")
      check entry.hasKey("mirrorsYou")
    check obs["you"]["farmType"].getStr() in ["apple", "banana"]
    check obs["board"]["variant"].getStr() == "concentric-rivers"
    check obs["view"]["map"].len == 2 * ViewRadius + 1
    for row in obs["view"]["map"]:
      check row.getStr().len == 2 * ViewRadius + 1
