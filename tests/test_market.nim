## tests/test_market.nim — the offer book.

import std/[unittest]

import fruit_market/sim, fruit_market/scripted

proc bench(): Sim =
  ## Eight cogs parked out of each other's way along the top of the orchard,
  ## so a test can place exactly the pair it wants to reason about.
  var config = defaultGameConfig()
  config.seed = 11
  result = initSim(config)
  for slot in 0 ..< Seats:
    result.cogs[slot].x = 1 + slot * 3
    result.cogs[slot].y = 16
    result.cogs[slot].farm = if slot mod 2 == 0: fApple else: fBanana
    ## Stocked to cover the widest legal offer on the side it posts, and empty
    ## on the other side so a receipt never trips the inventory cap by accident.
    result.cogs[slot].apples = if slot mod 2 == 0: 8 else: 0
    result.cogs[slot].bananas = if slot mod 2 == 0: 0 else: 8

proc place(sim: var Sim, slot, x, y: int, offer: Offer) =
  sim.cogs[slot].x = x
  sim.cogs[slot].y = y
  sim.cogs[slot].offer = offer
  sim.cogs[slot].offer.active = true

proc offer(give: Fruit, giveN, wantN: int): Offer =
  Offer(active: true, giveFruit: give, giveN: giveN,
    wantFruit: other(give), wantN: wantN)

suite "exact-mirror matching":
  test "only an exact mirror clears; each field perturbed in turn fails":
    for perturb in 0 .. 4:
      var sim = bench()
      sim.cogs[0].apples = 6
      sim.cogs[0].bananas = 0
      sim.cogs[1].apples = 0
      sim.cogs[1].bananas = 6
      var a = offer(fApple, 3, 2)
      var b = offer(fBanana, 2, 3)
      case perturb
      of 1: b.giveFruit = fApple; b.wantFruit = fBanana
      of 2: b.giveN = 3
      of 3: b.wantN = 4
      of 4: a.giveN = 4
      else: discard
      sim.place(0, 10, 8, a)
      sim.place(1, 11, 8, b)
      sim.refreshUnfunded()
      sim.executeTrades()
      if perturb == 0:
        check sim.totalTrades == 1
        check sim.cogs[0].apples == 3
        check sim.cogs[0].bananas == 2
        check not sim.cogs[0].offer.active
        check not sim.cogs[1].offer.active
      else:
        check sim.totalTrades == 0

  test "radius 3 clears, radius 4 does not":
    for dist in [3, 4]:
      var sim = bench()
      sim.place(0, 10, 8, offer(fApple, 3, 2))
      sim.place(1, 10 + dist, 8, offer(fBanana, 2, 3))
      sim.refreshUnfunded()
      sim.executeTrades()
      check sim.totalTrades == (if dist == 3: 1 else: 0)

  test "an unfunded offer never clears and says why":
    var sim = bench()
    sim.cogs[0].apples = 1
    sim.place(0, 10, 8, offer(fApple, 3, 2))
    sim.place(1, 11, 8, offer(fBanana, 2, 3))
    sim.refreshUnfunded()
    check sim.cogs[0].offer.unfunded
    sim.executeTrades()
    check sim.totalTrades == 0
    var reasons: seq[string]
    for event in sim.events:
      if event.kind == evUnfunded:
        reasons.add(event.reason)
    check reasons == @["stock"]

  test "receipt over invCap blocks the pair, with reason full":
    var sim = bench()
    sim.cogs[0].apples = 6
    sim.cogs[0].bananas = sim.config.invCap
    sim.place(0, 10, 8, offer(fApple, 3, 2))
    sim.place(1, 11, 8, offer(fBanana, 2, 3))
    sim.refreshUnfunded()
    check sim.cogs[0].offer.unfunded
    var reasons: seq[string]
    for event in sim.events:
      if event.kind == evUnfunded:
        reasons.add(event.reason)
    check reasons == @["full"]
    sim.executeTrades()
    check sim.totalTrades == 0

suite "the deterministic sweep":
  test "volume desc, distance asc, low slot asc, high slot asc":
    ## Four simultaneously clearable pairs. 4/5 is the biggest trade on the
    ## board and must clear first; 0/1 and 2/3 are the same volume, so the
    ## closer pair goes next; 6/7 is the smallest.
    var sim = bench()
    sim.place(0, 4, 8, offer(fApple, 3, 2))
    sim.place(1, 5, 8, offer(fBanana, 2, 3))      ## volume 5, dist 1
    sim.place(2, 10, 8, offer(fApple, 3, 2))
    sim.place(3, 13, 8, offer(fBanana, 2, 3))     ## volume 5, dist 3
    sim.place(4, 16, 8, offer(fApple, 6, 4))
    sim.place(5, 19, 8, offer(fBanana, 4, 6))     ## volume 10, dist 3
    sim.place(6, 22, 8, offer(fApple, 1, 1))
    sim.place(7, 23, 8, offer(fBanana, 1, 1))     ## volume 2, dist 1
    sim.refreshUnfunded()
    let candidates = sim.buildCandidates()
    check candidates.len == 4
    check (candidates[0].i, candidates[0].j) == (4, 5)
    check (candidates[1].i, candidates[1].j) == (0, 1)
    check (candidates[2].i, candidates[2].j) == (2, 3)
    check (candidates[3].i, candidates[3].j) == (6, 7)
    sim.executeTrades()
    check sim.totalTrades == 4

  test "a cog in two candidate pairs trades only in the first":
    var sim = bench()
    ## Slot 1 mirrors both 0 and 2; 0/1 is the bigger trade, so 2 goes unfilled.
    sim.place(0, 10, 8, offer(fApple, 4, 3))
    sim.place(1, 11, 8, offer(fBanana, 3, 4))
    sim.place(2, 12, 8, offer(fApple, 4, 3))
    for slot in 3 ..< Seats:
      sim.cogs[slot].offer = Offer()
    sim.refreshUnfunded()
    sim.executeTrades()
    check sim.totalTrades == 1
    check sim.cogs[0].trades == 1
    check sim.cogs[1].trades == 1
    check sim.cogs[2].trades == 0
    check sim.cogs[2].offer.active

  test "one trade per cog per tick and per round":
    var sim = bench()
    sim.place(0, 10, 8, offer(fApple, 3, 2))
    sim.place(1, 11, 8, offer(fBanana, 2, 3))
    for slot in 2 ..< Seats:
      sim.cogs[slot].offer = Offer()
    sim.refreshUnfunded()
    sim.executeTrades()
    check sim.totalTrades == 1
    ## Repost the same pair inside the same round: the round cap holds.
    sim.place(0, 10, 8, offer(fApple, 3, 2))
    sim.place(1, 11, 8, offer(fBanana, 2, 3))
    for slot in 0 ..< Seats:
      sim.cogs[slot].tradedThisTick = false
    sim.refreshUnfunded()
    sim.executeTrades()
    check sim.totalTrades == 1
    ## A new round clears the cap.
    sim.closeRound()
    for slot in 0 ..< Seats:
      sim.cogs[slot].tradedThisTick = false
    sim.place(0, 10, 8, offer(fApple, 3, 2))
    sim.place(1, 11, 8, offer(fBanana, 2, 3))
    sim.refreshUnfunded()
    sim.executeTrades()
    check sim.totalTrades == 2

suite "offer quantities":
  test "n outside 1..offerMax is clamped and flagged":
    let config = defaultGameConfig()
    check clampOfferN(config, 9) == (6, true)
    check clampOfferN(config, 0) == (1, true)
    check clampOfferN(config, -4) == (1, true)
    check clampOfferN(config, 4) == (4, false)

  test "the canonical baseline offers are exact mirrors of each other":
    check mirrors(canonicalOffer(fApple), canonicalOffer(fBanana))
    check applesPerBananaX100(3, 2) == CanonicalRateX100
