## The offer book: the funded check and the deterministic matching sweep.
##
## Matching is EXACT MIRROR IMAGE, as the idea states. Price-improvement
## matching was considered and rejected: it needs an arbitrary rule for
## splitting the surplus, and exact mirroring is what makes the book worth
## reading — to trade at all you must copy a counterparty's numbers, or get
## yours copied.

import std/[algorithm]

import ./sim_types, ./sim_config, ./sim_state, ./events

type
  Candidate* = object
    i*, j*: int      ## slots, i < j
    volume*: int     ## give_i.n + give_j.n
    dist*: int       ## Chebyshev

proc candidateLess*(a, b: Candidate): int =
  ## (a) total volume DESCENDING, (b) Chebyshev distance ASCENDING,
  ## (c) lower slot ascending, (d) higher slot ascending. Keys (c) and (d)
  ## identify a pair uniquely, so this is a TOTAL order and the tie-break is
  ## complete.
  if a.volume != b.volume:
    return cmp(b.volume, a.volume)
  if a.dist != b.dist:
    return cmp(a.dist, b.dist)
  if a.i != b.i:
    return cmp(a.i, b.i)
  cmp(a.j, b.j)

proc refreshUnfunded*(sim: var Sim) =
  ## Recomputed on EVERY tick from current inventories; a live offer that just
  ## became unfundable emits `unfunded` once per transition.
  for slot in 0 ..< Seats:
    if not sim.cogs[slot].offer.active:
      continue
    let check = sim.offerFunded(slot)
    let wasUnfunded = sim.cogs[slot].offer.unfunded
    sim.cogs[slot].offer.unfunded = not check.funded
    if not check.funded and not wasUnfunded:
      sim.emit(SimEvent(kind: evUnfunded, seat: slot, reason: check.reason))

proc buildCandidates*(sim: Sim): seq[Candidate] =
  ## Every unordered pair {i, j}, i < j by slot, where both offers are live and
  ## funded, the two offers mirror exactly, the pair is within tradeRadius, and
  ## neither side would exceed invCap on receipt.
  for i in 0 ..< Seats:
    let a = sim.cogs[i]
    if not a.offer.active or a.offer.unfunded:
      continue
    for j in i + 1 ..< Seats:
      let b = sim.cogs[j]
      if not b.offer.active or b.offer.unfunded:
        continue
      if not mirrors(a.offer, b.offer):
        continue
      let dist = chebyshev(a.x, a.y, b.x, b.y)
      if dist > sim.config.tradeRadius:
        continue
      if a.invOf(a.offer.wantFruit) + a.offer.wantN > sim.config.invCap:
        continue
      if b.invOf(b.offer.wantFruit) + b.offer.wantN > sim.config.invCap:
        continue
      result.add(Candidate(
        i: i, j: j, volume: a.offer.giveN + b.offer.giveN, dist: dist))
  result.sort(candidateLess)

proc executeTrades*(sim: var Sim) =
  ## Step 6 of the tick: sweep the sorted candidates and execute a pair iff
  ## neither cog has traded yet this tick AND neither has traded yet this
  ## round. An executed offer is CONSUMED on both sides.
  let candidates = sim.buildCandidates()
  for candidate in candidates:
    let
      i = candidate.i
      j = candidate.j
    if sim.cogs[i].tradedThisTick or sim.cogs[j].tradedThisTick:
      continue
    if sim.cogs[i].tradedThisRound or sim.cogs[j].tradedThisRound:
      continue
    let
      offerA = sim.cogs[i].offer
      offerB = sim.cogs[j].offer
    sim.cogs[i].addInv(offerA.giveFruit, -offerA.giveN)
    sim.cogs[i].addInv(offerA.wantFruit, offerA.wantN)
    sim.cogs[j].addInv(offerB.giveFruit, -offerB.giveN)
    sim.cogs[j].addInv(offerB.wantFruit, offerB.wantN)
    sim.cogs[i].offer = Offer()
    sim.cogs[j].offer = Offer()
    sim.cogs[i].tradedThisTick = true
    sim.cogs[j].tradedThisTick = true
    sim.cogs[i].tradedThisRound = true
    sim.cogs[j].tradedThisRound = true
    sim.cogs[i].trades.inc
    sim.cogs[j].trades.inc
    sim.cogs[i].volume += offerA.giveN
    sim.cogs[j].volume += offerB.giveN
    sim.totalTrades.inc
    let
      apples =
        if offerA.giveFruit == fApple: offerA.giveN else: offerB.giveN
      bananas =
        if offerA.giveFruit == fBanana: offerA.giveN else: offerB.giveN
      rate = applesPerBananaX100(apples, bananas)
    sim.rateVolume += bananas
    sim.rateWeighted += rate * bananas
    sim.lastRateX100 = rate
    sim.tape.add(TapeRow(
      t: sim.tick,
      giveFruit: offerA.giveFruit, giveN: offerA.giveN,
      wantFruit: offerA.wantFruit, wantN: offerA.wantN,
      applesPerBanana: rate, a: i, b: j))
    if sim.tape.len > 64:
      sim.tape.delete(0)
    sim.emit(SimEvent(
      kind: evTrade, a: i, b: j,
      aGive: offerA.giveFruit, aGiveN: offerA.giveN,
      bGive: offerB.giveFruit, bGiveN: offerB.giveN,
      applesPerBanana: rate,
      x: sim.cogs[i].x, y: sim.cogs[i].y, dist: candidate.dist))
    if sim.firstTradeTick < 0:
      sim.firstTradeTick = sim.tick
      sim.beat("firsttrade")

proc clampOfferN*(config: GameConfig, n: int): tuple[value: int, clamped: bool] =
  ## `n` outside 1..offerMax is CLAMPED to the range and the `offer` event
  ## records `"clamped": true`.
  let value = max(OfferMin, min(config.offerMax, n))
  (value, value != n)
