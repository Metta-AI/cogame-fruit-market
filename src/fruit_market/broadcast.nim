## The broadcast chrome frame: the JSON `TextMessage` the viewer reads to draw
## the scorebug, clock, roster strip, order book, feed and end-card.
##
## Fork of coworld-ctf `src/ctf/broadcast.nim`. `teams` becomes the two guilds
## (`apple` / `banana`), `roster` the eight cogs, and `lead` the exchange-rate
## series — fed exactly like paintbot's lives series, so `ingestLeadSeries` and
## `renderMomentum` in `client/chrome_common.js` need NO change.

import std/[algorithm, json, strutils]

import ./sim_types, ./sim_config, ./sim_state, ./sim, ./replays

type
  ChromeCog* = object
    slot*: int
    x*, y*: int
    apples*, bananas*: int
    hunger*, stamina*, score*: int
    flags*: int
    offerGive*: int      ## fruit id, -1 = no offer
    offerGiveN*: int
    offerWantN*: int
    offerUnfunded*: bool

  ChromeView* = object
    tick*, maxTick*, startTick*: int
    rounds*, ticksPerRound*: int
    phase*: string        ## lobby | playing | gameover
    playing*: bool
    speed*: int
    looping*: bool
    transportEnabled*: bool
    boardScale*: int
    names*: array[Seats, string]
    policyNames*: array[Seats, string]
    farmTypes*: array[Seats, Fruit]
    colors*: array[Seats, string]
    cogs*: array[Seats, ChromeCog]
    rateX100*: int
    events*: JsonNode
    sendLead*: bool
    rate*: seq[array[2, int]]
    beats*: seq[Beat]
    over*: JsonNode
    summary*: string

proc guildOf*(fruit: Fruit): string =
  if fruit == fApple: "apple" else: "banana"

proc guildLabel*(fruit: Fruit): string =
  if fruit == fApple: "Apple Farmers" else: "Banana Farmers"

proc teamsJson(view: ChromeView): JsonNode =
  ## Two plates keyed `apple` and `banana`. The big number (`lives`) is the
  ## guild's TOTAL SCORE — the scorebug's `Lives` label is re-lettered `Score`
  ## in the page.
  result = newJObject()
  for fruit in [fApple, fBanana]:
    var
      total = 0
      trades = 0
      volume = 0
    for slot in 0 ..< Seats:
      if view.farmTypes[slot] != fruit:
        continue
      total += view.cogs[slot].score
    result[guildOf(fruit)] = %*{
      "lives": total,
      "flag": "home",
      "carrier": -1,
      "prog": 0,
      "policies": [guildLabel(fruit)],
      "trades": trades,
      "volume": volume
    }

proc rosterJson(view: ChromeView): JsonNode =
  ## Alias in `name`, the POLICY name in `pol` — both name spaces, not either.
  result = newJArray()
  for slot in 0 ..< Seats:
    let cog = view.cogs[slot]
    result.add(%*{
      "s": slot,
      "team": guildOf(view.farmTypes[slot]),
      "name": view.names[slot],
      "pol": view.policyNames[slot],
      "col": slot,
      "colName": view.colors[slot],
      "alive": (cog.flags and FlagExhausted) == 0,
      "lives": cog.score,
      "hp": cog.hunger,
      "carry": false,
      "k": 0, "d": 0, "cap": 0, "mk2": 0, "mk3": 0, "tk": 0,
      "farm": $view.farmTypes[slot],
      "apples": cog.apples,
      "bananas": cog.bananas,
      "hunger": cog.hunger,
      "stamina": cog.stamina,
      "score": cog.score,
      "exhausted": (cog.flags and FlagExhausted) != 0,
      "starving": (cog.flags and FlagStarving) != 0
    })

proc stallNameAt(x, y: int): string =
  ## The stall this offer is standing at, or "" when the cog is out in the
  ## board. The kernel's `market` job parks within Chebyshev 1 of the named
  ## stall, so this is exactly "where you can meet it" — and it is derived from
  ## the recorded cell, so the live frame and the replay frame agree.
  for id in StallId:
    if chebyshev(x, y, StallCells[id][0], StallCells[id][1]) <= 1:
      return $id
  ""

proc bookJson(view: ChromeView): JsonNode =
  ## Every live offer, sorted by volume then slot — the "all offers logged"
  ## surface made visible.
  var rows: seq[JsonNode]
  for slot in 0 ..< Seats:
    let cog = view.cogs[slot]
    if cog.offerGive < 0:
      continue
    rows.add(%*{
      "s": slot,
      "name": view.names[slot],
      "give": $fruitOfId(cog.offerGive),
      "giveN": cog.offerGiveN,
      "want": $fruitOfId(1 - cog.offerGive),
      "wantN": cog.offerWantN,
      "unfunded": cog.offerUnfunded,
      "stall": stallNameAt(cog.x, cog.y)
    })
  rows.sort(proc (a, b: JsonNode): int =
    let volA = a["giveN"].getInt + a["wantN"].getInt
    let volB = b["giveN"].getInt + b["wantN"].getInt
    if volA != volB: cmp(volB, volA) else: cmp(a["s"].getInt, b["s"].getInt))
  result = newJArray()
  for row in rows:
    result.add(row)

proc buildStateJson*(view: ChromeView): string =
  var state = %*{
    "t": view.tick,
    "mt": view.maxTick,
    "ph": view.phase,
    "lob": 0,
    "pl": view.playing,
    "sp": view.speed,
    "mx": view.maxTick,
    "st": view.startTick,
    "lp": view.looping,
    "sk": false,
    "ff": false,
    "en": view.transportEnabled,
    "mm": -1,
    "bs": view.boardScale,
    "pov": -1,
    "teams": view.teamsJson(),
    "roster": view.rosterJson(),
    "events": (if view.events.isNil: newJArray() else: view.events)
  }
  ## The fruit-market block: everything the appended game block draws that the
  ## inherited chrome has no field for.
  state["fm"] = %*{
    "round": min(view.rounds, view.tick div max(1, view.ticksPerRound) + 1),
    "rounds": view.rounds,
    "tick": view.tick,
    "ticks": view.maxTick + 1,
    "rate": view.rateX100,
    "book": view.bookJson(),
    "book_rate": CanonicalRateX100
  }
  if view.sendLead:
    var pts = newJArray()
    for row in view.rate:
      pts.add(%*[row[0], row[1]])
    ## The shape `ingestLeadSeries` expects: {"teams": [...], "pts": [[t, v]]}.
    state["lead"] = %*{"teams": ["rate"], "pts": pts}
    var beats = newJArray()
    for beat in view.beats:
      var node = %*{"t": beat.t, "k": beat.kind}
      if beat.kind == "round":
        node["n"] = %beat.n
      if beat.seat >= 0:
        node["seat"] = %beat.seat
      beats.add(node)
    state["beats"] = beats
  if not view.over.isNil and view.over.kind == JObject:
    state["over"] = view.over
    state["fm"]["summary"] = %view.summary
  $state

proc overJson*(results: JsonNode, names, policyNames: array[Seats, string],
    farmTypes: array[Seats, Fruit]): JsonNode =
  ## The end-card is STATE, not an event: present on every game-over frame so a
  ## viewer who seeks straight to the end still sees the verdict.
  var
    best = -1
    bestSlot = 0
    winners = newJArray()
  let scores = results{"scores"}
  for slot in 0 ..< Seats:
    let score = (if scores.isNil or slot >= scores.len: 0
                 else: scores[slot].getInt())
    if score > best:
      best = score
      bestSlot = slot
  for slot in 0 ..< Seats:
    let score = (if scores.isNil or slot >= scores.len: 0
                 else: scores[slot].getInt())
    if score == best:
      winners.add(%names[slot])
  var teams = newJObject()
  for fruit in [fApple, fBanana]:
    var total = 0
    for slot in 0 ..< Seats:
      if farmTypes[slot] != fruit:
        continue
      total += (if scores.isNil or slot >= scores.len: 0
                else: scores[slot].getInt())
    teams[guildOf(fruit)] = %*{"lives": total, "prog": 0}
  let ending = results{"ending"}.getStr("round_limit")
  %*{
    "winner": guildOf(farmTypes[bestSlot]),
    "draw": winners.len > 1,
    "timeLimit": ending == "deadline",
    "teams": teams,
    "endingKey": ending,
    "ending": (
      case ending
      of "famine": "FAMINE"
      of "deadline": "TIME"
      of "forfeit": "FORFEIT"
      else: "ROUND LIMIT"),
    "winnerAlias": names[bestSlot],
    "winnerPolicy": policyNames[bestSlot],
    "winnerScore": best,
    "scores": (if scores.isNil: newJArray() else: scores),
    "aliases": (block:
      var arr = newJArray()
      for slot in 0 ..< Seats:
        arr.add(%names[slot])
      arr)
  }

proc chromeViewOfSim*(sim: Sim, events: JsonNode, sendLead: bool): ChromeView =
  ## The live `/global` frame.
  result.tick = max(0, sim.tick - 1)
  result.maxTick = max(1, sim.config.totalTicks() - 1)
  result.startTick = 0
  result.rounds = sim.config.rounds
  result.ticksPerRound = sim.config.ticksPerRound
  result.phase = if sim.done: "gameover" else: "playing"
  result.playing = not sim.done
  result.speed = 1
  result.looping = false
  result.transportEnabled = false
  result.boardScale = 1
  result.rateX100 = sim.lastRateX100
  result.events = events
  result.sendLead = sendLead
  result.rate = sim.rate
  result.beats = sim.beats
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    result.names[slot] = sim.aliases[slot]
    result.policyNames[slot] = sim.policyNames[slot]
    result.farmTypes[slot] = cog.farm
    result.colors[slot] = CogColorNames[slot]
    var flags = 0
    if cog.exhausted: flags = flags or FlagExhausted
    if cog.hunger == 0: flags = flags or FlagStarving
    if cog.tradedThisRound: flags = flags or FlagTraded
    if cog.wading: flags = flags or FlagWading
    result.cogs[slot] = ChromeCog(
      slot: slot, x: cog.x, y: cog.y,
      apples: cog.apples, bananas: cog.bananas,
      hunger: cog.hunger, stamina: cog.stamina, score: cog.score,
      flags: flags,
      offerGive: (if cog.offer.active: fruitId(cog.offer.giveFruit) else: -1),
      offerGiveN: cog.offer.giveN,
      offerWantN: cog.offer.wantN,
      offerUnfunded: cog.offer.unfunded)
  if sim.done:
    let results = sim.resultsJson()
    result.over = overJson(results, result.names, result.policyNames,
      result.farmTypes)
    result.summary = ""

proc chromeViewOfReplay*(replay: Replay, index: int, playing: bool,
    speed: int, looping: bool, sendLead: bool, events: JsonNode): ChromeView =
  ## The static-bundle frame: the same shape, read out of the replay bytes.
  let frame = replay.frames[clamp(index, 0, replay.frames.high)]
  result.tick = frame.t
  result.maxTick = replay.maxTick()
  result.startTick = 0
  result.rounds = replay.rounds
  result.ticksPerRound = replay.ticksPerRound
  result.phase = if index >= replay.frames.high: "gameover" else: "playing"
  result.playing = playing
  result.speed = speed
  result.looping = looping
  result.transportEnabled = true
  result.boardScale = 1
  result.rateX100 = replay.rateAt(frame.t)
  result.events = events
  result.sendLead = sendLead
  result.rate = replay.rate
  result.beats = replay.beats
  result.names = replay.names
  result.policyNames = replay.policyNames
  result.farmTypes = replay.farmTypes
  result.colors = replay.colors
  for slot in 0 ..< Seats:
    result.cogs[slot] = ChromeCog(
      slot: slot,
      x: frame.cogAt(slot, 0), y: frame.cogAt(slot, 1),
      apples: frame.cogAt(slot, 2), bananas: frame.cogAt(slot, 3),
      hunger: frame.cogAt(slot, 4), stamina: frame.cogAt(slot, 5),
      score: frame.cogAt(slot, 6), flags: frame.cogAt(slot, 7),
      offerGive: frame.offerAt(slot, 0),
      offerGiveN: frame.offerAt(slot, 1),
      offerWantN: frame.offerAt(slot, 2),
      offerUnfunded: frame.offerAt(slot, 3) != 0)
  if index >= replay.frames.high:
    result.over = overJson(replay.results, replay.names, replay.policyNames,
      replay.farmTypes)
    result.summary = replay.replaySummaryLine()
