## tests/test_llm.nim — the decision layer.
##
## No outbound network: the transport is exercised through `decideAll` against
## a STUB HTTP server on 127.0.0.1 that times out, 429s, 403s or answers junk,
## through the client disabled (the hosted no-credentials path), and through
## the parser, the batch builder and the extractor directly.

import std/[json, net, os, strutils, times, unittest]

import curly

import fruit_market/sim, fruit_market/scripted, fruit_market/llm

type StubMode = enum
  smJunk        ## 200 with prose and no JSON object
  smThrottle    ## 429
  smForbidden   ## 403
  smSilent      ## answers so late the client's own deadline fires first

var
  stubMode: StubMode
  stubPort: int
  stubListener: Socket
  stubThread: Thread[void]

proc stubAccept() =
  let listener = stubListener
  while true:
    var client: Socket
    try:
      listener.accept(client)
    except CatchableError:
      continue
    try:
      ## Drain the request head; the body is irrelevant to a stub.
      while true:
        let line = client.recvLine(timeout = 2000)
        if line.len == 0 or line == "\r\n":
          break
      let body =
        case stubMode
        of smJunk: """I think I will go to the market, but I will not say so in JSON."""
        of smThrottle: """{"type":"error","error":{"type":"overloaded"}}"""
        of smForbidden: """{"type":"error","error":{"type":"forbidden"}}"""
        of smSilent: """{"content":[{"type":"text","text":"{}"}]}"""
      let status =
        case stubMode
        of smThrottle: "429 Too Many Requests"
        of smForbidden: "403 Forbidden"
        else: "200 OK"
      if stubMode == smSilent:
        ## Outlast llmTimeoutSeconds so the client's own deadline fires.
        sleep(2500)
      client.send("HTTP/1.1 " & status & "\r\nContent-Type: application/json" &
        "\r\nContent-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" &
        body)
    except CatchableError:
      discard
    try:
      client.close()
    except CatchableError:
      discard

proc stubServe() {.thread.} =
  ## A deliberately dumb HTTP/1.1 server: read the request, answer once, close.
  ## It is bound to 127.0.0.1 and is the only endpoint this test can reach.
  {.gcsafe.}:
    stubAccept()

proc startStub(mode: StubMode) =
  ## Points the Bedrock branch of `newLlmClient` at the stub. One server for the
  ## whole file; the mode is switched between tests.
  if stubPort == 0:
    ## Bind here, in the test thread, so a busy port is a retry rather than a
    ## dead server thread and a mystery connection refused.
    stubListener = newSocket()
    stubListener.setSockOpt(OptReuseAddr, true)
    for candidate in 45180 .. 45260:
      try:
        stubListener.bindAddr(Port(candidate), "127.0.0.1")
        stubPort = candidate
        break
      except CatchableError:
        discard
    doAssert stubPort != 0, "no free loopback port for the stub transport"
    stubListener.listen()
    stubMode = mode
    createThread(stubThread, stubServe)
    sleep(100)
  stubMode = mode
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:" & $stubPort)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "stub-token")

proc stubClient(timeoutSeconds = 1): LlmClient =
  var config = defaultGameConfig()
  config.llmTimeoutSeconds = timeoutSeconds
  newLlmClient(config)

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

suite "a stubbed transport degrades to the scripted order":
  ## Every one of these routes a REAL request through curly to the stub and
  ## asserts the seat still gets a legal hauler order marked `fallback` — the
  ## record phase 60 counts. Nothing raises out of `decideAll`, ever.
  proc runAgainstStub(mode: StubMode, openSeats = Seats,
      timeoutSeconds = 1): array[Seats, Order] =
    startStub(mode)
    let client = stubClient(timeoutSeconds)
    check not client.disabled          ## the stub IS a credentialed transport
    var game = bench()
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      prompts[slot] = "trade well"
      scripts[slot] = if slot < openSeats: skNone else: skHauler
      connected[slot] = true
    client.decideAll(game, prompts, scripts, connected)

  test "junk with no JSON object falls back and is recorded as fallback":
    let game = bench()
    let orders = runAgainstStub(smJunk)
    for slot in 0 ..< Seats:
      check orders[slot].source == osFallback
      check orders[slot].job in {jHarvest, jMarket, jTrek, jRest}
      var want = scriptedOrder(game, slot, skHauler)
      want.source = osFallback
      check orders[slot] == want

  test "a 429 falls back and leaves the client enabled for the next round":
    startStub(smThrottle)
    let client = stubClient()
    var game = bench()
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      scripts[slot] = skNone
      connected[slot] = true
    let orders = client.decideAll(game, prompts, scripts, connected)
    for slot in 0 ..< Seats:
      check orders[slot].source == osFallback
    ## 429 is a throttle, not an auth failure: the seat is retried next round.
    check not client.disabled

  test "a 403 falls back and disables the client for the rest of the episode":
    startStub(smForbidden)
    let client = stubClient()
    var game = bench()
    var prompts: array[Seats, string]
    var scripts: array[Seats, ScriptKind]
    var connected: array[Seats, bool]
    for slot in 0 ..< Seats:
      scripts[slot] = skNone
      connected[slot] = true
    let orders = client.decideAll(game, prompts, scripts, connected)
    for slot in 0 ..< Seats:
      check orders[slot].source == osFallback
    check client.disabled

  test "a transport that outlasts llmTimeoutSeconds falls back, bounded":
    ## One open seat, so the wall clock is two attempts of the 1 s deadline.
    let started = epochTime()
    let orders = runAgainstStub(smSilent, openSeats = 1)
    let elapsed = epochTime() - started
    check orders[0].source == osFallback
    check orders[1].source == osScripted
    check elapsed < 20.0

suite "the batch and the pacing floor":
  test "one batch carries every open seat":
    ## `decideAll` opens exactly the seats that are connected and not
    ## registered as scripted — eight on round one — and issues them as ONE
    ## parallel batch. Asserting on the RequestBatch itself is what keeps a
    ## future refactor from quietly going sequential.
    var game = bench()
    var prompts: array[Seats, string]
    var open: seq[int]
    for slot in 0 ..< Seats:
      prompts[slot] = "trade well"
      open.add(slot)
    startStub(smJunk)
    let client = stubClient()
    let batch = client.buildBatch(game, prompts, open, 0)
    check batch.len == open.len
    check batch.len == Seats
    var tags: seq[string]
    for i in 0 ..< batch.len:
      tags.add(batch[i].tag)
      check batch[i].verb == "POST"
    for slot in 0 ..< Seats:
      check $slot in tags
    ## The retry batch carries the hint, and only the seats still open.
    let retry = client.buildBatch(game, prompts, @[3], 1)
    check retry.len == 1
    check "previous reply was invalid" in retry[0].body

  test "a max_tokens stop raises the named error, not 'unbalanced JSON'":
    expect FruitMarketError:
      discard textOfBody("""{"stop_reason":"max_tokens","content":[
        {"type":"text","text":"Let me think about which stall to walk to"}]}""")
    var named = ""
    try:
      discard textOfBody("""{"stop_reason":"max_tokens","content":[
        {"type":"text","text":"Let me think about which stall"}]}""")
    except FruitMarketError as error:
      named = error.msg
    check "cut off at max_tokens" in named
    ## A max_tokens stop that still carried the whole object is not an error.
    check "{" in textOfBody("""{"stop_reason":"max_tokens","content":[
      {"type":"text","text":"{\"job\":\"rest\"}"}]}""")

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
