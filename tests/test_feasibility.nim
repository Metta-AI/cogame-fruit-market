## tests/test_feasibility.nim — the oracle, as a CI precondition.
##
## Gates (a)-(d) of the design note's `## The game`, over seeds 1..12 on all
## four variants. Any constant change that breaks the economy fails HERE rather
## than in a dead replay.

import std/[strutils, unittest]

import fruit_market/sim, fruit_market/scripted

type Variant = object
  id: string
  rivers, water, regrow: int

const Variants = [
  Variant(id: "open-market", rivers: 0, water: 0, regrow: 60),
  Variant(id: "concentric-rivers", rivers: 2, water: 10, regrow: 60),
  Variant(id: "deep-rivers", rivers: 2, water: 32, regrow: 60),
  Variant(id: "lean-harvest", rivers: 2, water: 10, regrow: 90),
]

const Seeds = 1 .. 12

proc play(v: Variant, seed: int, kinds: array[Seats, ScriptKind]): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.rivers = v.rivers
  config.moveStaminaWater = v.water
  config.regrowTicks = v.regrow
  result = initSim(config)
  while not result.done:
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(result, slot, kinds[slot])
    result.setRoundOrders(orders)
    result.runRound()

proc uniform(kind: ScriptKind): array[Seats, ScriptKind] =
  for slot in 0 ..< Seats:
    result[slot] = kind

proc split(first, second: ScriptKind, swap = false): array[Seats, ScriptKind] =
  for slot in 0 ..< Seats:
    result[slot] = if (slot < 4) != swap: first else: second

proc meanOf(sim: Sim, kinds: array[Seats, ScriptKind], kind: ScriptKind): float =
  var total = 0
  var count = 0
  for slot in 0 ..< Seats:
    if kinds[slot] == kind:
      total += sim.cogs[slot].score
      count.inc
  if count == 0: 0.0 else: total.float / count.float

suite "gate (a): the baselines make a market":
  for variant in Variants:
    test variant.id:
      let kinds = uniform(skHauler)
      var complete = 0
      for seed in Seeds:
        let sim = play(variant, seed, kinds)
        if sim.reason == "complete" and sim.ending == "round_limit":
          complete.inc
        check sim.totalTrades >= 24
        for slot in 0 ..< Seats:
          check sim.cogs[slot].score >= 60
          check sim.cogs[slot].starvingTicks <= 120
      ## This is what makes certification, docker-smoke and all-filler league
      ## episodes end `complete`.
      check complete >= 10

suite "gate (b): trade beats autarky":
  for variant in Variants:
    test variant.id:
      var haulers = 0.0
      var homesteaders = 0.0
      for seed in Seeds:
        for swap in [false, true]:
          let kinds = split(skHauler, skHomesteader, swap)
          let sim = play(variant, seed, kinds)
          haulers += sim.meanOf(kinds, skHauler)
          homesteaders += sim.meanOf(kinds, skHomesteader)
      checkpoint(variant.id & ": hauler " & haulers.formatFloat(ffDecimal, 1) &
        " vs homesteader " & homesteaders.formatFloat(ffDecimal, 1))
      check haulers >= 1.5 * homesteaders

suite "gate (c): geography bites":
  test "deep-rivers taxes the recluse harder than the trader":
    proc measure(variant: Variant): tuple[hauler, homesteader: float] =
      var hauler = 0.0
      var homesteader = 0.0
      for seed in Seeds:
        for swap in [false, true]:
          let kinds = split(skHauler, skHomesteader, swap)
          let sim = play(variant, seed, kinds)
          hauler += sim.meanOf(kinds, skHauler)
          homesteader += sim.meanOf(kinds, skHomesteader)
      (hauler, homesteader)
    let open = measure(Variants[0])
    let deep = measure(Variants[2])
    checkpoint("open " & $open & " deep " & $deep)
    ## The homesteader is strictly worse off once the rivers are deep.
    check deep.homesteader < open.homesteader
    ## And the trader's LEAD over it is strictly larger. Lead is measured as a
    ## RATIO, not a difference: the trader commutes to the market ring every
    ## round and the recluse is capped by its eat budget long before its
    ## stamina, so a deeper river costs the trader absolute points too — the
    ## difference cannot rise even when the tax lands hardest on the recluse.
    check deep.hauler / deep.homesteader > open.hauler / open.homesteader

suite "gate (d): reading the book is viable":
  for variant in Variants:
    test variant.id:
      var mirror = 0.0
      var hauler = 0.0
      for seed in Seeds:
        for swap in [false, true]:
          let kinds = split(skHauler, skMirror, swap)
          let sim = play(variant, seed, kinds)
          hauler += sim.meanOf(kinds, skHauler)
          mirror += sim.meanOf(kinds, skMirror)
      checkpoint(variant.id & ": mirror " & mirror.formatFloat(ffDecimal, 1) &
        " vs hauler " & hauler.formatFloat(ffDecimal, 1))
      check mirror >= hauler
