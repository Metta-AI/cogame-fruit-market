## tests/test_sim.nim — sim units and determinism.

import std/[os, osproc, strutils, tables, unittest]

import fruit_market/sim, fruit_market/scripted

proc episodeHash*(seed: int): uint64 =
  ## One all-hauler episode, played to its natural end. The determinism test
  ## runs this twice in this process and once in a FRESH process (below).
  var config = defaultGameConfig()
  config.seed = seed
  config.rounds = 12
  var sim = initSim(config)
  while not sim.done:
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(sim, slot, skHauler)
    sim.setRoundOrders(orders)
    sim.runRound()
  doAssert sim.ticksPlayed == 720
  sim.gameHash()

const HashFlag = "--emit-game-hash"

## A FRESH SERVER, not a second call: re-exec this binary with the flag and it
## plays the episode from a cold process and prints the hash. Anything that
## made the sim depend on process state — a global left set by an earlier test,
## an address, a clock — shows up as a different number.
if paramCount() >= 2 and paramStr(1) == HashFlag:
  echo episodeHash(parseInt(paramStr(2)))
  quit(0)

proc freshSim(seed = 1): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  initSim(config)

proc placeAt(sim: var Sim, slot, x, y: int) =
  sim.cogs[slot].x = x
  sim.cogs[slot].y = y

proc parkEveryoneElse(sim: var Sim, keep: int) =
  ## Move every other cog into a corner of the wall-adjacent ring so it cannot
  ## collide with the seat under test.
  var spot = 0
  for slot in 0 ..< Seats:
    if slot == keep:
      continue
    sim.placeAt(slot, 1 + spot, 1)
    spot.inc

proc restOrder(fruit: Fruit): Order =
  Order(job: jRest, fruit: fruit, eat: epNone, source: osScripted)

suite "PLAYER_SCRIPTED":
  test "only the two shipped baselines are selectable; mirror is not":
    ## `mirror` is gate (d)'s book reader and lives in tests/test_feasibility.
    ## It is not a shipped policy, so the production image must not field it
    ## for a seat that asks for it by name.
    check parseScriptKind("") == skNone
    check parseScriptKind("hauler") == skHauler
    check parseScriptKind("HOMESTEADER") == skHomesteader
    check parseScriptKind("autarky") == skHomesteader
    check parseScriptKind("mirror") == skHauler
    check parseScriptKind("whatever") == skHauler

suite "harvest":
  test "3 of your own fruit, 1 of the other, with the right cooldown":
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.parkEveryoneElse(0)
    ## Stand beside the apple tree at (3, 2).
    sim.placeAt(0, 3, 1)
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jHarvest, fruit: fApple, hasFruit: true,
      eat: epNone, source: osScripted)
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].apples == 3
    check sim.cogs[0].harvestCd == sim.config.harvestCooldownOwn - 1
    check sim.board.trees[0].bareFor == sim.config.regrowTicks

    ## A bare tree yields nothing and regrows at exactly regrowTicks. Park the
    ## cog first, or the kernel walks it to the next ripe tree.
    orders[0] = restOrder(fApple)
    sim.setRoundOrders(orders)
    for _ in 0 ..< sim.config.regrowTicks:
      sim.stepTick()
    check sim.board.trees[0].bareFor == 0
    check sim.cogs[0].apples == 3

  test "the other fruit yields 1 on the long cooldown":
    var sim = freshSim()
    sim.cogs[0].farm = fBanana
    sim.parkEveryoneElse(0)
    sim.placeAt(0, 3, 1)
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jHarvest, fruit: fApple, hasFruit: true,
      eat: epNone, source: osScripted)
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].apples == 1
    check sim.cogs[0].harvestCd == sim.config.harvestCooldownOther - 1

  test "a yield over invCap spills":
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.parkEveryoneElse(0)
    sim.placeAt(0, 3, 1)
    sim.cogs[0].apples = sim.config.invCap - 1
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jHarvest, fruit: fApple, hasFruit: true,
      eat: epNone, source: osScripted)
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].apples == sim.config.invCap
    var spilled = 0
    for event in sim.events:
      if event.kind == evSpill:
        spilled += event.lost
    check spilled == 2

suite "movement":
  test "land and water cost their own stamina and cooldown":
    var sim = freshSim()
    sim.parkEveryoneElse(0)
    sim.placeAt(0, 16, 1)
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    sim.setRoundOrders(orders)
    let before = sim.cogs[0].stamina
    sim.stepMoveForTest(aMoveS)
    check sim.cogs[0].y == 2
    check sim.cogs[0].stamina == before - sim.config.moveStaminaLand
    check sim.cogs[0].moveCd == sim.config.moveCooldown
    sim.cogs[0].moveCd = 0
    let beforeWater = sim.cogs[0].stamina
    sim.stepMoveForTest(aMoveS)
    check sim.board.isWater(sim.cogs[0].x, sim.cogs[0].y)
    check sim.cogs[0].stamina == beforeWater - sim.config.moveStaminaWater
    check sim.cogs[0].moveCd == sim.config.waterMoveCooldown

  test "a move it cannot pay for is refused":
    var sim = freshSim()
    sim.parkEveryoneElse(0)
    sim.placeAt(0, 16, 2)
    sim.cogs[0].stamina = sim.config.moveStaminaWater - 1
    sim.stepMoveForTest(aMoveS)
    check sim.cogs[0].y == 2

  test "two cogs cannot share a cell and the lower slot wins":
    var sim = freshSim()
    for slot in 2 ..< Seats:
      sim.placeAt(slot, 1 + slot, 1)
    sim.placeAt(0, 10, 1)
    sim.placeAt(1, 12, 1)
    var actions: array[Seats, Action]
    for slot in 0 ..< Seats:
      actions[slot] = aWait
    actions[0] = aMoveE
    actions[1] = aMoveW
    sim.stepMoveAllForTest(actions)
    check sim.cogs[0].x == 11
    check sim.cogs[1].x == 12

suite "hunger, stamina and eating":
  test "hunger drains on the period and the 0 crossing emits starve once":
    var sim = freshSim()
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    sim.setRoundOrders(orders)
    for slot in 0 ..< Seats:
      sim.cogs[slot].hunger = 2
    for _ in 0 ..< 12:
      sim.stepTick()
    check sim.cogs[0].hunger == 0
    var starves = 0
    for event in sim.events:
      if event.kind == evStarve and event.seat == 0:
        starves.inc
    check starves == 1
    check sim.cogs[0].stamina < StaminaMax

  test "starveDrain empties stamina and emits exhausted":
    var sim = freshSim()
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    sim.setRoundOrders(orders)
    for slot in 0 ..< Seats:
      sim.cogs[slot].hunger = 0
      sim.cogs[slot].stamina = 3
    for _ in 0 ..< 4:
      sim.stepTick()
    check sim.cogs[0].stamina == 0
    check sim.cogs[0].exhausted
    var exhausted = 0
    for event in sim.events:
      if event.kind == evExhausted and event.seat == 0:
        exhausted.inc
    check exhausted == 1

  test "a move that spends the last stamina emits exhausted too":
    ## The event table's condition is "stamina reached 0", not "the starvation
    ## drain reached 0": a cog that pays its last point walking into the river
    ## collapses in full view and the feed says so.
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.parkEveryoneElse(0)
    sim.placeAt(0, 10, 1)              ## clear of the parked seats at x 1..7
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    sim.setRoundOrders(orders)
    ## On an ODD tick, so the +1 regen of step 8 does not paper over it.
    sim.stepTick()
    sim.cogs[0].hunger = 50            ## not starving: only the move can do it
    sim.cogs[0].stamina = sim.config.moveStaminaLand
    sim.cogs[0].moveCd = 0
    sim.stepMoveForTest(aMoveE, 0)
    check sim.cogs[0].x == 11
    check sim.cogs[0].stamina == 0
    sim.stepTick()
    check sim.cogs[0].exhausted
    var exhausted = 0
    for event in sim.events:
      if event.kind == evExhausted and event.seat == 0:
        exhausted.inc
    check exhausted == 1

  test "stamina regenerates only while hunger is above 0":
    var sim = freshSim()
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    sim.setRoundOrders(orders)
    sim.cogs[0].stamina = 50
    sim.cogs[0].hunger = 50
    sim.cogs[1].stamina = 50
    sim.cogs[1].hunger = 0
    for _ in 0 ..< 4:
      sim.stepTick()
    check sim.cogs[0].stamina > 50
    check sim.cogs[1].stamina < 50

  test "eating is gated by eatCooldown, capped at hungerMax, and scores":
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.cogs[0].apples = 6
    sim.cogs[0].bananas = 6
    sim.cogs[0].hunger = 90
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jRest, eat: epCrave, source: osScripted)
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].bananas == 5
    check sim.cogs[0].hunger == HungerMax        ## surplus above the cap is lost
    check sim.cogs[0].score == sim.config.craveScore
    check sim.cogs[0].cravedEaten == 1
    for _ in 0 ..< sim.config.eatCooldown - 1:
      sim.stepTick()
    check sim.cogs[0].bananas == 5                ## still on cooldown
    sim.stepTick()
    check sim.cogs[0].bananas == 4

  test "eat: any falls back to your own fruit and scores 1":
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.cogs[0].apples = 4
    sim.cogs[0].bananas = 0
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jRest, eat: epAny, source: osScripted)
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].apples == 3
    check sim.cogs[0].score == sim.config.ownScore
    check sim.cogs[0].ownEaten == 1

  test "an exhausted cog can still eat and still trade":
    var sim = freshSim()
    sim.cogs[0].farm = fApple
    sim.cogs[1].farm = fBanana
    for slot in 2 ..< Seats:
      sim.placeAt(slot, 1 + slot, 1)
    sim.placeAt(0, 16, 4)
    sim.placeAt(1, 17, 4)
    sim.cogs[0].stamina = 0
    sim.cogs[0].exhausted = true
    sim.cogs[0].apples = 6
    sim.cogs[0].bananas = 0
    sim.cogs[1].bananas = 6
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = restOrder(sim.cogs[slot].farm)
    orders[0] = Order(job: jRest, eat: epCrave, source: osScripted,
      hasOfferKey: true, offer: canonicalOffer(fApple))
    orders[1] = Order(job: jRest, eat: epNone, source: osScripted,
      hasOfferKey: true, offer: canonicalOffer(fBanana))
    sim.setRoundOrders(orders)
    sim.stepTick()
    check sim.cogs[0].trades == 1
    check sim.cogs[0].apples == 3                ## gave 3 away while exhausted
    check sim.cogs[0].bananas == 1               ## received 2, ate one of them
    check sim.cogs[0].score == sim.config.craveScore

suite "the seeded farm-type shuffle":
  test "exactly four of each type, seed-stable, not slot-stable":
    var layouts = initCountTable[string]()
    for seed in 1 .. 100:
      var config = defaultGameConfig()
      config.seed = seed
      let sim = initSim(config)
      var apples = 0
      var key = ""
      for slot in 0 ..< Seats:
        if sim.cogs[slot].farm == fApple:
          apples.inc
        key.add(if sim.cogs[slot].farm == fApple: "a" else: "b")
      check apples == 4
      layouts.inc(key)
      ## Same seed, same shuffle.
      var again = defaultGameConfig()
      again.seed = seed
      let twice = initSim(again)
      for slot in 0 ..< Seats:
        check twice.cogs[slot].farm == sim.cogs[slot].farm
    check layouts.len > 1

suite "determinism":
  test "the same seed and the same orders give the same gameHash":
    let first = episodeHash(4242)
    let second = episodeHash(4242)
    check first == second
    ## A different seed is a different episode, or the hash proves nothing.
    check episodeHash(4243) != first

  test "and the same hash again across a fresh server":
    ## Twice in one process AND across a fresh process: the second half is what
    ## catches a sim that quietly depends on something the process carried in.
    let inProcess = episodeHash(4242)
    let child = execProcess(getAppFilename(), args = [HashFlag, "4242"],
      options = {})
    check child.strip().len > 0
    check child.strip() == $inProcess
