## Sim state: the record every other module reads, the seeded farm-type
## shuffle, spawn placement, logging, event emission and `gameHash`.
##
## Fork of coworld-ctf `src/ctf/sim_state.nim`.

import std/[json, random, strutils, unicode]

import ./sim_types, ./sim_config, ./board, ./events

type
  Sim* = object
    config*: GameConfig
    board*: Board
    cogs*: array[Seats, Cog]
    aliases*: array[Seats, string]
    policyNames*: array[Seats, string]
    tick*: int
    round*: int              ## rounds completed
    roundsPlayed*: int
    done*: bool
    reason*: string          ## complete | deadline | forfeit
    ending*: string          ## round_limit | famine | deadline | forfeit
    famineLatched*: bool
    firstTradeTick*: int
    events*: seq[SimEvent]
    frames*: seq[Frame]
    rate*: seq[array[2, int]]  ## [tick, applesPerBanana x100]
    beats*: seq[Beat]
    tape*: seq[TapeRow]
    history*: array[Seats, seq[RoundRow]]
    totalTrades*: int
    rateVolume*: int           ## banana units traded, the rate's weight
    rateWeighted*: int         ## sum of applesPerBanana x100 * bananas
    lastRateX100*: int
    rng*: Rand
    recordFrames*: bool

const CanonicalRateX100* = 150
  ## The baselines' 3-for-2 book price. Drawn as the dashed reference on the
  ## exchange-rate chart and used before the first print.

proc cleanText*(text: string, limit: int): string =
  ## Rune-boundary truncation. A BYTE cut put invalid UTF-8 into a replay and
  ## only a strict parser found it (bullwhip, 2026-08-22), so every string that
  ## reaches the replay goes through here.
  result = text.strip().replace("\n", " ").replace("\r", " ")
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc shuffleFarmTypes*(rng: var Rand): array[Seats, Fruit] =
  ## The idea's anti-collusion clause: four apples and four bananas, shuffled
  ## over slots 0..7 by the seeded RNG (Fisher-Yates, descending index). Slot
  ## n is not a stable type across episodes and a cog never learns another
  ## cog's type except from what it offers.
  for slot in 0 ..< Seats:
    result[slot] = if slot < 4: fApple else: fBanana
  for i in countdown(Seats - 1, 1):
    let j = rng.rand(i)
    swap(result[i], result[j])

proc emit*(sim: var Sim, event: SimEvent) =
  var row = event
  row.t = sim.tick
  sim.events.add(row)

proc beat*(sim: var Sim, kind: string, n = 0, seat = -1) =
  sim.beats.add(Beat(t: sim.tick, kind: kind, n: n, seat: seat))

proc invOf*(cog: Cog, fruit: Fruit): int =
  if fruit == fApple: cog.apples else: cog.bananas

proc addInv*(cog: var Cog, fruit: Fruit, n: int) =
  if fruit == fApple: cog.apples += n else: cog.bananas += n

proc craved*(cog: Cog): Fruit = other(cog.farm)

proc offerFunded*(sim: Sim, slot: int): tuple[funded: bool, reason: string] =
  ## An offer whose owner does not hold `give.n`, or which would overflow the
  ## inventory cap on receipt, is unfunded: still in the book, drawn hollow,
  ## unable to clear.
  let cog = sim.cogs[slot]
  if not cog.offer.active:
    return (true, "")
  if cog.invOf(cog.offer.giveFruit) < cog.offer.giveN:
    return (false, "stock")
  if cog.invOf(cog.offer.wantFruit) + cog.offer.wantN > sim.config.invCap:
    return (false, "full")
  (true, "")

proc initSim*(config: GameConfig, policyNames: openArray[string] = []): Sim =
  result.config = config
  result.board = initBoard(config.rivers)
  result.rng = initRand(config.seed + 1)
  result.firstTradeTick = -1
  result.lastRateX100 = CanonicalRateX100
  result.recordFrames = true
  let farmTypes = shuffleFarmTypes(result.rng)
  let spawns = spawnCells(farmTypes)
  for slot in 0 ..< Seats:
    result.aliases[slot] = CogAliases[slot]
    ## Platform-supplied, but it reaches results.names and the replay's
    ## policyNames, so it goes through the same rune-safe truncation as every
    ## other recorded string: a byte cut here puts invalid UTF-8 in a replay
    ## and only a strict parser finds it (bullwhip, 2026-08-22).
    result.policyNames[slot] =
      if slot < policyNames.len and policyNames[slot].strip().len > 0:
        cleanText(policyNames[slot], MaxPolicyNameLen)
      else:
        CogAliases[slot]
    result.cogs[slot] = Cog(
      x: spawns[slot][0],
      y: spawns[slot][1],
      farm: farmTypes[slot],
      apples: 0,
      bananas: 0,
      hunger: config.hunger0,
      stamina: Stamina0,
      score: 0
    )
    result.cogs[slot].order = Order(
      job: jHarvest, fruit: farmTypes[slot], hasFruit: true,
      eat: epAny, source: osScripted)

proc farmTypesOf*(sim: Sim): seq[Fruit] =
  for slot in 0 ..< Seats:
    result.add(sim.cogs[slot].farm)

proc gameHash*(sim: Sim): uint64 =
  ## FNV-1a over the whole per-cog state and every tree counter. Cosmetic
  ## fields (say, notes, latency) are deliberately excluded — determinism is
  ## about the SIM, and a hash that moved with an LLM string would be useless.
  result = 0xcbf29ce484222325'u64
  proc mix(h: var uint64, value: int) =
    var v = uint64(value) and 0xffffffff'u64
    for shift in [0, 8, 16, 24]:
      h = h xor ((v shr shift) and 0xff'u64)
      h = h * 0x100000001b3'u64
  mix(result, sim.tick)
  mix(result, sim.round)
  for cog in sim.cogs:
    mix(result, cog.x)
    mix(result, cog.y)
    mix(result, cog.apples)
    mix(result, cog.bananas)
    mix(result, cog.hunger)
    mix(result, cog.stamina)
    mix(result, cog.score)
    mix(result, ord(cog.farm))
    mix(result, ord(cog.offer.active))
    mix(result, cog.offer.giveN)
    mix(result, cog.offer.wantN)
    mix(result, ord(cog.offer.giveFruit))
    mix(result, cog.moveCd)
    mix(result, cog.harvestCd)
    mix(result, cog.eatCd)
  for tree in sim.board.trees:
    mix(result, tree.bareFor)

proc echoLog*(sim: Sim, parts: varargs[string, `$`]) =
  var line = "fruit-market t" & $sim.tick & ": "
  for part in parts:
    line.add(part)
  echo line

proc resultsJson*(sim: Sim): JsonNode =
  ## `names` are POLICY names (platform side); aliases go to the players and
  ## into the replay's `names[]`.
  var
    names = newJArray()
    aliases = newJArray()
    farmTypes = newJArray()
    scores = newJArray()
    win = newJArray()
    cravedEaten = newJArray()
    ownEaten = newJArray()
    harvested = newJArray()
    trades = newJArray()
    volume = newJArray()
    crossings = newJArray()
    starving = newJArray()
  var best = 0
  for slot in 0 ..< Seats:
    best = max(best, sim.cogs[slot].score)
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    names.add(%sim.policyNames[slot])
    aliases.add(%sim.aliases[slot])
    farmTypes.add(%($cog.farm))
    scores.add(%cog.score)
    win.add(%(cog.score == best))
    cravedEaten.add(%cog.cravedEaten)
    ownEaten.add(%cog.ownEaten)
    harvested.add(%cog.harvested)
    trades.add(%cog.trades)
    volume.add(%cog.volume)
    crossings.add(%cog.crossings)
    starving.add(%cog.starvingTicks)
  %*{
    "names": names,
    "aliases": aliases,
    "farm_types": farmTypes,
    "scores": scores,
    "win": win,
    "craved_eaten": cravedEaten,
    "own_eaten": ownEaten,
    "harvested": harvested,
    "trades": trades,
    "volume": volume,
    "crossings": crossings,
    "starving_ticks": starving,
    "mean_rate_x100":
      (if sim.rateVolume > 0: sim.rateWeighted div sim.rateVolume else: 0),
    "total_trades": sim.totalTrades,
    "rounds": sim.roundsPlayed,
    "reason": (if sim.reason.len > 0: sim.reason else: "complete"),
    "ending": (if sim.ending.len > 0: sim.ending else: "round_limit")
  }
