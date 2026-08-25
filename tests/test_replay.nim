## tests/test_replay.nim — end-to-end plus strict UTF-8.

import std/[json, os, strutils, unicode, unittest]

import fruit_market/sim, fruit_market/scripted, fruit_market/replays,
  fruit_market/broadcast

proc playEpisode(seed = 3, rounds = 12): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.rounds = rounds
  result = initSim(config)
  while not result.done:
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(result, slot, skHauler)
    result.setRoundOrders(orders)
    result.runRound()

suite "the replay document":
  var sim = playEpisode()
  let results = sim.resultsJson()
  let bytes = $replayJson(sim, results)
  let dir = getTempDir() / "fruit-market-test"
  createDir(dir)
  let path = dir / "replay.json"
  writeFile(path, bytes)
  let raw = readFile(path)

  test "it is strict UTF-8 and parses as one JSON document":
    check validateUtf8(raw) == -1
    let node = parseJson(raw)
    check node.kind == JObject
    check node["protocol"].getStr() == "fruit-market.replay.v1"
    check node["game"].getStr() == "fruit-market"

  test "one frame and one rate row per tick played":
    let node = parseJson(raw)
    check node["frames"].len == sim.ticksPlayed
    check node["series"]["rate"].len == sim.ticksPlayed
    check sim.ticksPlayed == 720

  test "every event tick is inside the episode and the vocabulary is complete":
    let node = parseJson(raw)
    var kinds: seq[string]
    var rounds = 0
    var ends = 0
    for row in node["events"]:
      let t = row["t"].getInt()
      check t >= 0
      check t <= sim.ticksPlayed
      let kind = row["k"].getStr()
      if kind notin kinds:
        kinds.add(kind)
      if kind == "round": rounds.inc
      if kind == "end": ends.inc
    for required in ["harvest", "offer", "trade", "eat", "order", "round", "end"]:
      check required in kinds
    check rounds == sim.config.rounds
    check ends == 1

  test "the results block travels inside the replay bytes":
    let node = parseJson(raw)
    check node["results"]["scores"].len == Seats
    check node["results"]["reason"].getStr() in
      ["complete", "deadline", "forfeit"]
    check node["results"]["ending"].getStr() in
      ["round_limit", "famine", "deadline", "forfeit"]
    check node["results"]["names"].len == Seats
    check node["results"]["aliases"].len == Seats

  test "config carries every constant the viewer reads":
    let node = parseJson(raw)["config"]
    for key in ["variant", "cols", "rows", "cell", "rounds", "ticksPerRound",
        "water", "trees", "stalls", "spawns", "invCap", "hungerMax", "hunger0",
        "hungerDrainPeriod", "craveNutrition", "ownNutrition", "craveScore",
        "ownScore", "eatCooldown", "staminaMax", "staminaRegenPeriod",
        "starveDrain", "moveStaminaLand", "moveStaminaWater", "moveCooldown",
        "waterMoveCooldown", "harvestCooldownOwn", "harvestCooldownOther",
        "yieldOwn", "yieldOther", "regrowTicks", "tradeRadius", "viewRadius",
        "offerMin", "offerMax"]:
      check node.hasKey(key)
    check node["trees"].len == 48

  test "the last beat is gameover at the final tick":
    let node = parseJson(raw)
    check node["beats"].len > 0
    let last = node["beats"][node["beats"].len - 1]
    check last["k"].getStr() == "gameover"
    check last["t"].getInt() == sim.ticksPlayed - 1
    var kinds: seq[string]
    for beat in node["beats"]:
      let kind = beat["k"].getStr()
      if kind notin kinds:
        kinds.add(kind)
    for kind in kinds:
      check kind in ["round", "firsttrade", "starve", "famine", "gameover"]

  test "it round-trips through the viewer's own parser":
    let replay = parseReplay(raw)
    check replay.frames.len == sim.ticksPlayed
    check replay.board.trees.len == 48
    check replay.maxTick() == sim.ticksPlayed - 1
    check replay.rateAt(0) == CanonicalRateX100

  test "the file stays under 8 MiB":
    check getFileSize(path) < 8 * 1024 * 1024

suite "the viewer's display is the recorded state":
  ## Fruit Market records STATE, not inputs, so playback never re-simulates.
  ## What has to hold instead is that the bytes the viewer reads ARE the state
  ## the sim was in, tick by tick, and that the recorded events tell the same
  ## story as the recorded frames. Both are asserted here.
  var sim = playEpisode(seed = 4, rounds = 6)
  let raw = $replayJson(sim, sim.resultsJson())
  let replay = parseReplay(raw)

  test "every recorded frame survives the parse unchanged":
    check replay.frames.len == sim.frames.len
    for index, frame in replay.frames:
      check frame.t == sim.frames[index].t
      for i in 0 ..< frame.c.len:
        check frame.c[i] == sim.frames[index].c[i]
      for i in 0 ..< frame.o.len:
        check frame.o[i] == sim.frames[index].o[i]
      check frame.r == sim.frames[index].r

  test "the chrome frame the viewer draws is that frame, field for field":
    ## chromeViewOfReplay is the ONLY source the static bundle draws from;
    ## every number it reports is read positionally out of the frame.
    for index in countup(0, replay.frames.high, 7):
      let
        frame = replay.frames[index]
        view = chromeViewOfReplay(replay, index, true, 1, false, false,
          newJArray())
      check view.tick == frame.t
      for slot in 0 ..< Seats:
        let cog = view.cogs[slot]
        check cog.x == frame.cogAt(slot, 0)
        check cog.y == frame.cogAt(slot, 1)
        check cog.apples == frame.cogAt(slot, 2)
        check cog.bananas == frame.cogAt(slot, 3)
        check cog.hunger == frame.cogAt(slot, 4)
        check cog.stamina == frame.cogAt(slot, 5)
        check cog.score == frame.cogAt(slot, 6)
        check cog.flags == frame.cogAt(slot, 7)
        check cog.offerGive == frame.offerAt(slot, 0)
        check cog.offerGiveN == frame.offerAt(slot, 1)
        check cog.offerWantN == frame.offerAt(slot, 2)
        check cog.offerUnfunded == (frame.offerAt(slot, 3) != 0)

  test "replaying the recorded events reproduces the recorded frames":
    ## The events are the audit trail ("all offers logged"); the frames are
    ## what the viewer draws. Walk the events tick by tick, keep the books
    ## they imply, and require them to agree with EVERY frame: a harvest that
    ## never landed, a trade recorded on one side only or an eat that scored
    ## the wrong seat all fail here.
    var
      apples: array[Seats, int]
      bananas: array[Seats, int]
      score: array[Seats, int]
      rows = 0
    proc give(slot: int, fruit: string, n: int) =
      if fruit == "apple": apples[slot] += n else: bananas[slot] += n
    var events: seq[JsonNode]
    for row in parseJson(raw)["events"]:
      events.add(row)
    var at = 0
    for index, frame in replay.frames:
      while at < events.len and events[at]["t"].getInt() <= frame.t:
        let row = events[at]
        at.inc
        rows.inc
        case row["k"].getStr()
        of "harvest":
          give(row["seat"].getInt(), row["fr"].getStr(), row["n"].getInt())
        of "eat":
          give(row["seat"].getInt(), row["fr"].getStr(), -1)
          score[row["seat"].getInt()] += row["points"].getInt()
        of "trade":
          let
            a = row["a"].getInt()
            b = row["b"].getInt()
          give(a, row["aGive"].getStr(), -row["aGiveN"].getInt())
          give(b, row["bGive"].getStr(), -row["bGiveN"].getInt())
          give(a, row["bGive"].getStr(), row["bGiveN"].getInt())
          give(b, row["aGive"].getStr(), row["aGiveN"].getInt())
        else:
          discard
      for slot in 0 ..< Seats:
        check apples[slot] == frame.cogAt(slot, 2)
        check bananas[slot] == frame.cogAt(slot, 3)
        check score[slot] == frame.cogAt(slot, 6)
    check rows > 0
    ## And the results block the replay carries is the same arithmetic again.
    for slot in 0 ..< Seats:
      check replay.results["scores"][slot].getInt() == score[slot]

suite "the forfeit replay is still playable":
  test "no seat connected: results, and a replay the viewer's parser accepts":
    ## design note: forfeit is "all zero; results + replay are still written".
    ## A replay whose `frames` array is empty is one `parseReplay` refuses, so
    ## the static viewer would set data-replay-error on it instead of showing
    ## the board nobody turned up to.
    var config = defaultGameConfig()
    config.seed = 12
    var sim = initSim(config)
    sim.forfeit()
    let results = sim.resultsJson()
    check results["reason"].getStr() == "forfeit"
    check results["ending"].getStr() == "forfeit"
    for slot in 0 ..< Seats:
      check results["scores"][slot].getInt() == 0
    let bytes = $replayJson(sim, results)
    check validateUtf8(bytes) == -1
    let replay = parseReplay(bytes)
    check replay.frames.len == 1
    check replay.maxTick() == 0
    check replay.beats[^1].kind == "gameover"
    let frame = parseJson(buildStateJson(
      chromeViewOfReplay(replay, 0, false, 1, false, true, newJArray())))
    check frame["ph"].getStr() == "gameover"
    check frame["over"]["ending"].getStr() == "FORFEIT"
    check frame["roster"].len == Seats

suite "rune-boundary truncation":
  test "a say and notes of multi-byte runes are cut on rune boundaries":
    ## The bullwhip byte-truncation bug: a byte cut puts invalid UTF-8 into a
    ## replay and only a strict parser ever finds it.
    let wide = "\u00e9\u4e2d\u00e5\u00f8\u2764"          ## 5 runes, 12 bytes
    var say = ""
    while say.runeLen < MaxSayLen * 2:
      say.add(wide)
    var notes = ""
    while notes.runeLen < MaxNotesLen * 2:
      notes.add(wide)
    let cleanSay = cleanText(say, MaxSayLen)
    let cleanNotes = cleanText(notes, MaxNotesLen)
    check validateUtf8(cleanSay) == -1
    check validateUtf8(cleanNotes) == -1
    check cleanSay.runeLen <= MaxSayLen
    check cleanNotes.runeLen <= MaxNotesLen

    var config = defaultGameConfig()
    config.seed = 5
    config.rounds = 2
    var sim = initSim(config)
    while not sim.done:
      var orders: array[Seats, Order]
      for slot in 0 ..< Seats:
        orders[slot] = scriptedOrder(sim, slot, skHauler)
        orders[slot].say = cleanSay
        orders[slot].notes = cleanNotes
      sim.setRoundOrders(orders)
      sim.runRound()
    let bytes = $replayJson(sim, sim.resultsJson())
    check validateUtf8(bytes) == -1
    let node = parseJson(bytes)
    var checkedRows = 0
    for row in node["events"]:
      if row["k"].getStr() != "order":
        continue
      checkedRows.inc
      check validateUtf8(row["say"].getStr()) == -1
      check validateUtf8(row["notes"].getStr()) == -1
      check row["say"].getStr().runeLen <= MaxSayLen
      check row["notes"].getStr().runeLen <= MaxNotesLen
    check checkedRows == Seats * 2

  test "a policy name is cut on a rune boundary before it reaches the replay":
    ## The platform supplies these, but they land in the replay's policyNames
    ## and in results.names, and the note's rule is EVERY string that reaches
    ## the replay.
    var wide = ""
    while wide.runeLen < MaxPolicyNameLen * 3:
      wide.add("\u00e9\u4e2d\u00f8")
    var names: seq[string]
    for slot in 0 ..< Seats:
      names.add(wide & "\n policy " & $slot)
    var config = defaultGameConfig()
    config.seed = 6
    config.rounds = 1
    var sim = initSim(config, names)
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(sim, slot, skHauler)
    sim.setRoundOrders(orders)
    sim.runRound()
    let bytes = $replayJson(sim, sim.resultsJson())
    check validateUtf8(bytes) == -1
    let node = parseJson(bytes)
    for slot in 0 ..< Seats:
      let recorded = node["policyNames"][slot].getStr()
      check validateUtf8(recorded) == -1
      check recorded.runeLen <= MaxPolicyNameLen
      check "\n" notin recorded
      check node["results"]["names"][slot].getStr() == recorded

  test "LLM error text is capped at 200 runes, on a rune boundary":
    var long = ""
    while long.runeLen < 900:
      long.add("\u00e9\u4e2d")
    let capped = cleanText(long, MaxErrorLen)
    check validateUtf8(capped) == -1
    check capped.runeLen <= MaxErrorLen
