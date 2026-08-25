## tests/test_baseline.nim — bounded orders and legality.
##
## Both shipped baselines, over every variant, asserted move by move: an order
## outside its enum, an offer outside 1..offerMax, a cog inside a wall, a
## negative inventory or a score that went backwards is a bug in the sim, not
## a bad roll.

import std/[times, unittest]

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

proc configFor(v: Variant, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rivers = v.rivers
  result.moveStaminaWater = v.water
  result.regrowTicks = v.regrow

proc checkOrder(sim: Sim, slot: int, order: Order) =
  check order.job in {jHarvest, jMarket, jTrek, jRest}
  check order.fruit in {fApple, fBanana}
  check order.eat in {epCrave, epAny, epNone}
  if order.hasStall:
    check order.stall in {stNorth, stEast, stSouth, stWest}
  if order.hasOfferKey and not order.withdraw:
    check order.offer.giveFruit != order.offer.wantFruit
    check order.offer.giveN >= OfferMin
    check order.offer.giveN <= sim.config.offerMax
    check order.offer.wantN >= OfferMin
    check order.offer.wantN <= sim.config.offerMax
    ## An offer posted from the STALL is funded at the moment of posting. The
    ## hauler deliberately leaves the same offer standing while it restocks —
    ## the book marks it `unfunded` and it cannot clear, which is the design's
    ## own rule for a bluff, so only the market case is asserted here.
    if order.job == jMarket:
      check sim.cogs[slot].invOf(order.offer.giveFruit) >= order.offer.giveN

proc checkState(sim: Sim, lastScores: var array[Seats, int]) =
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    check onBoard(cog.x, cog.y)
    check sim.board.zoneAt(cog.x, cog.y) != zWall
    check not sim.board.isTree(cog.x, cog.y)
    check cog.apples >= 0
    check cog.bananas >= 0
    check cog.apples <= sim.config.invCap
    check cog.bananas <= sim.config.invCap
    check cog.hunger >= 0
    check cog.hunger <= HungerMax
    check cog.stamina >= 0
    check cog.stamina <= StaminaMax
    check cog.score >= lastScores[slot]
    lastScores[slot] = cog.score
    for other in slot + 1 ..< Seats:
      check not (cog.x == sim.cogs[other].x and cog.y == sim.cogs[other].y)

suite "the scripted baselines are bounded and legal":
  for variant in Variants:
    for mix in 0 .. 2:
      test variant.id & " / mix " & $mix:
        var kinds: array[Seats, ScriptKind]
        for slot in 0 ..< Seats:
          kinds[slot] =
            case mix
            of 0: skHauler
            of 1: skHomesteader
            else: (if slot < 4: skHauler else: skHomesteader)
        for seed in 1 .. 3:
          var sim = initSim(configFor(variant, seed))
          var lastScores: array[Seats, int]
          var worstRoundMs = 0.0
          while not sim.done:
            var orders: array[Seats, Order]
            let started = epochTime()
            for slot in 0 ..< Seats:
              orders[slot] = scriptedOrder(sim, slot, kinds[slot])
              sim.checkOrder(slot, orders[slot])
            worstRoundMs = max(worstRoundMs,
              (epochTime() - started) * 1000.0)
            sim.setRoundOrders(orders)
            for _ in 0 ..< sim.config.ticksPerRound:
              sim.stepTick()
              sim.checkState(lastScores)
            sim.closeRound()
            if sim.roundsPlayed >= sim.config.rounds:
              sim.finish("complete", "round_limit")
          check sim.ticksPlayed == sim.config.totalTicks()
          ## Deciding a whole round of eight scripted orders is a Dijkstra per
          ## seat over 576 cells: it has to stay off the critical path.
          check worstRoundMs < 50.0

suite "two haulers of opposite type in range always clear":
  test "within two ticks, on every variant":
    for variant in Variants:
      var sim = initSim(configFor(variant, 5))
      sim.cogs[0].farm = fApple
      sim.cogs[1].farm = fBanana
      sim.cogs[0].apples = 6
      sim.cogs[1].bananas = 6
      for slot in 2 ..< Seats:
        sim.cogs[slot].x = 1 + slot
        sim.cogs[slot].y = 16
      sim.cogs[0].x = 16
      sim.cogs[0].y = 4
      sim.cogs[1].x = 17
      sim.cogs[1].y = 4
      var orders: array[Seats, Order]
      for slot in 0 ..< Seats:
        orders[slot] = scriptedOrder(sim, slot, skHauler)
      check orders[0].hasOfferKey and not orders[0].withdraw
      check orders[1].hasOfferKey and not orders[1].withdraw
      check mirrors(orders[0].offer, orders[1].offer)
      sim.setRoundOrders(orders)
      sim.stepTick()
      sim.stepTick()
      check sim.totalTrades >= 1

suite "the per-tick action vocabulary":
  test "the kernel only ever emits the six actions":
    var sim = initSim(configFor(Variants[1], 9))
    var kinds: array[Seats, ScriptKind]
    for slot in 0 ..< Seats:
      kinds[slot] = if slot mod 2 == 0: skHauler else: skHomesteader
    for round in 0 ..< 4:
      var orders: array[Seats, Order]
      for slot in 0 ..< Seats:
        orders[slot] = scriptedOrder(sim, slot, kinds[slot])
      sim.setRoundOrders(orders)
      for _ in 0 ..< sim.config.ticksPerRound:
        for slot in 0 ..< Seats:
          check sim.kernelAction(slot) in
            {aWait, aMoveN, aMoveE, aMoveS, aMoveW, aHarvest}
        sim.stepTick()
      sim.closeRound()
