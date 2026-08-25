## tests/test_replay.nim — end-to-end plus strict UTF-8.

import std/[json, os, strutils, unicode, unittest]

import fruit_market/sim, fruit_market/scripted, fruit_market/replays

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

  test "LLM error text is capped at 200 runes, on a rune boundary":
    var long = ""
    while long.runeLen < 900:
      long.add("\u00e9\u4e2d")
    let capped = cleanText(long, MaxErrorLen)
    check validateUtf8(capped) == -1
    check capped.runeLen <= MaxErrorLen
