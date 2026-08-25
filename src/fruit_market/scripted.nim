## The two scripted baselines, both fieldable, both league fillers.
##
## `hauler` is the working baseline, the league's first filler, and the
## fallback every failed LLM decision lands on. `homesteader` is the autarky
## foil and the reason the rivers exist. A test-only `mirror` kernel reads the
## book; it lives here for gate (d) of the feasibility oracle and is NOT a
## shipped policy.
##
## Every field either baseline emits is inside its declared enum by
## construction, and every offer it posts is funded at the moment of posting —
## both asserted in tests/test_baseline.nim.

import ./sim_types, ./sim_config, ./board, ./sim_state, ./sim

const HaulerStock* = 3
const HaulerEatGuard* = 99
  ## How much of its own fruit a hauler banks before it goes to market. The
  ## design note's first cut was 3 — exactly one canonical offer — which made
  ## the baseline spend every other round walking back to its grove and cost
  ## it half its fills. Banking three offers' worth is what makes gate (a)'s
  ## trade count and gate (b)'s margin hold (tests/test_feasibility.nim).

proc canonicalOffer*(farm: Fruit): Offer =
  ## The book price. An apple farmer posts give 3 apple / want 2 banana; a
  ## banana farmer posts give 2 banana / want 3 apple. These two are exact
  ## mirrors of each other by construction, so any two haulers of opposite type
  ## that meet within three cells always trade — at 1.50 apples per banana.
  if farm == fApple:
    Offer(active: true, giveFruit: fApple, giveN: 3,
      wantFruit: fBanana, wantN: 2)
  else:
    Offer(active: true, giveFruit: fBanana, giveN: 2,
      wantFruit: fApple, wantN: 3)

proc rendezvousStall*(round: int): StallId =
  ## The round's rendezvous. Four stalls and eight wordless cogs: a cog that is
  ## not already trading has to guess where the others will be, and the only
  ## guess everyone can make together is "the stall of the round". Two rounds
  ## per stall, north -> east -> south -> west, so a hauler that walks in from
  ## the far grove still arrives while the crowd is there.
  StallId((max(1, round) - 1) div 2 mod 4)

proc haulerOrder*(sim: Sim, slot: int): Order =
  let cog = sim.cogs[slot]
  result.eat = if cog.hunger <= 45: epAny else: epCrave
  result.source = osScripted
  if cog.invOf(cog.farm) < HaulerStock:
    ## Restocking. The offer STAYS on the book (it is simply `unfunded` until
    ## the stock is back), because an apple tree at d==1 is only two cells from
    ## the market ring: a hauler can harvest and still be inside tradeRadius of
    ## a counterparty standing at the stall.
    result.job = jHarvest
    result.fruit = cog.farm
    result.hasFruit = true
    result.hasOfferKey = true
    result.offer = canonicalOffer(cog.farm)
    result.say =
      if cog.farm == fApple: "3 apples for 2 bananas"
      else: "2 bananas for 3 apples"
    return
  result.job = jMarket
  ## Stand where the counterparties are. Four stalls and eight wordless cogs:
  ## the only meeting point everyone can guess together is the stall of the
  ## round, and a baseline that walks to its OWN nearest stall instead spends
  ## the episode posting into an empty ring (measured: 10 fills, against 34
  ## for the rendezvous).
  result.stall = rendezvousStall(sim.roundOf())
  result.hasStall = true
  result.hasOfferKey = true
  result.offer = canonicalOffer(cog.farm)
  result.say =
    if cog.farm == fApple: "3 apples for 2 bananas"
    else: "2 bananas for 3 apples"

proc homesteaderOrder*(sim: Sim, slot: int): Order =
  let cog = sim.cogs[slot]
  result.source = osScripted
  result.eat = if cog.invOf(cog.craved()) > 0: epCrave else: epAny
  result.hasOfferKey = true
  result.withdraw = true      ## it never trades
  result.say = "I grow my own"
  if cog.stamina < 25:
    result.job = jRest
    result.eat = epAny
    return
  if cog.invOf(cog.farm) < 4:
    result.job = jHarvest
    result.fruit = cog.farm
    result.hasFruit = true
    return
  result.job = jTrek
  result.fruit = cog.craved()
  result.hasFruit = true

proc mirrorOrder*(sim: Sim, slot: int): Order =
  ## TEST ONLY (feasibility gate d): post the exact mirror of the
  ## highest-volume offer within view whose `want` is the fruit it grows, else
  ## the canonical book price. Against a room that only ever posts the book
  ## price it is byte-identical to `hauler`; the edge appears the moment
  ## somebody posts something else, which is what "reading the book is viable"
  ## has to mean.
  let cog = sim.cogs[slot]
  result = haulerOrder(sim, slot)
  result.source = osScripted
  var
    bestVolume = -1
    best = -1
  for other in 0 ..< Seats:
    if other == slot:
      continue
    let their = sim.cogs[other]
    if not their.offer.active:
      continue
    if chebyshev(cog.x, cog.y, their.x, their.y) > sim.config.viewRadius:
      continue
    if their.offer.wantFruit != cog.farm:
      continue
    if their.offer.giveN > bestVolume:
      bestVolume = their.offer.giveN
      best = other
  if best < 0:
    return
  let their = sim.cogs[best].offer
  result.offer = Offer(active: true,
    giveFruit: their.wantFruit, giveN: their.wantN,
    wantFruit: their.giveFruit, wantN: their.giveN)
  result.hasOfferKey = true
  result.withdraw = false

proc scriptedOrder*(sim: Sim, slot: int, kind: ScriptKind): Order =
  ## Rule-based baseline for `slot`. Always legal.
  case kind
  of skHomesteader: homesteaderOrder(sim, slot)
  of skMirror: mirrorOrder(sim, slot)
  else: haulerOrder(sim, slot)
