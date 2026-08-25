## The Fruit Market gameplay core: the nine numbered tick steps, the round
## boundary, the end conditions, and the module that re-exports the rest of
## `src/fruit_market/` so `import fruit_market/sim` sees everything (paintbot's
## split, same rule).

import std/[json]

import ./sim_types, ./sim_config, ./board, ./events, ./sim_state, ./market,
  ./kernel

export sim_types, sim_config, board, events, sim_state, market, kernel

proc roundOf*(sim: Sim): int =
  ## The 1-based round the current tick belongs to.
  sim.tick div sim.config.ticksPerRound + 1

proc setRoundOrders*(sim: var Sim, orders: array[Seats, Order]) =
  ## Stage a round's orders. The offer half lands in step 5 of the boundary
  ## tick, which is what makes "posted at a round boundary" exact; the `order`
  ## event is emitted here, one per seat per round boundary.
  let round = sim.tick div sim.config.ticksPerRound + 1
  for slot in 0 ..< Seats:
    let order = orders[slot]
    sim.cogs[slot].order = order
    sim.cogs[slot].hasOrder = true
    sim.cogs[slot].notes = order.notes
    sim.emit(SimEvent(kind: evOrder, seat: slot, round: round,
      job: order.job,
      fruit: (if order.hasFruit: order.fruit else: sim.cogs[slot].farm),
      stall: order.stall, hasStall: order.hasStall, eat: order.eat,
      hasOffer: order.hasOfferKey and not order.withdraw,
      give: order.offer.giveFruit, giveN: order.offer.giveN,
      want: order.offer.wantFruit, wantN: order.offer.wantN,
      source: order.source, say: order.say, notes: order.notes,
      latencyMs: order.latencyMs))

# --- step 1 -----------------------------------------------------------------

proc stepRegrow(sim: var Sim) =
  for tree in sim.board.trees.mitems:
    if tree.bareFor > 0:
      tree.bareFor.dec

# --- step 3 -----------------------------------------------------------------

proc stepHarvest(sim: var Sim, actions: array[Seats, Action]) =
  for slot in 0 ..< Seats:
    if actions[slot] != aHarvest:
      continue
    var cog = sim.cogs[slot]
    if cog.exhausted or cog.harvestCd > 0:
      continue
    let at = sim.adjacentAnyRipeTree(cog.x, cog.y)
    if at < 0:
      continue
    let tree = sim.board.trees[at]
    let own = tree.fruit == cog.farm
    let amount = if own: sim.config.yieldOwn else: sim.config.yieldOther
    let held = cog.invOf(tree.fruit)
    let taken = min(amount, max(0, sim.config.invCap - held))
    let lost = amount - taken
    cog.addInv(tree.fruit, taken)
    cog.harvested += taken
    cog.stamina = max(0, cog.stamina - 1)
    cog.harvestCd =
      if own: sim.config.harvestCooldownOwn
      else: sim.config.harvestCooldownOther
    sim.cogs[slot] = cog
    sim.board.trees[at].bareFor = sim.config.regrowTicks
    sim.emit(SimEvent(kind: evHarvest, seat: slot, fruit: tree.fruit,
      n: taken, x: tree.x, y: tree.y))
    if lost > 0:
      sim.emit(SimEvent(kind: evSpill, seat: slot, fruit: tree.fruit,
        lost: lost))

# --- step 4 -----------------------------------------------------------------

proc occupied(sim: Sim, x, y: int): bool =
  for slot in 0 ..< Seats:
    if sim.cogs[slot].x == x and sim.cogs[slot].y == y:
      return true
  false

proc stepMove(sim: var Sim, actions: array[Seats, Action]) =
  for slot in 0 ..< Seats:
    sim.cogs[slot].wading = false
    let action = actions[slot]
    if action notin {aMoveN, aMoveE, aMoveS, aMoveW}:
      continue
    var cog = sim.cogs[slot]
    if cog.exhausted or cog.moveCd > 0:
      continue
    let dir =
      case action
      of aMoveN: 0
      of aMoveE: 1
      of aMoveS: 2
      else: 3
    let
      nx = cog.x + StepDx[dir]
      ny = cog.y + StepDy[dir]
    if not sim.board.passable(nx, ny):
      continue
    ## A cell a lower-numbered seat already moved into this tick counts as
    ## occupied — the move sweep runs against the LIVE board.
    if sim.occupied(nx, ny):
      continue
    let intoWater = sim.board.isWater(nx, ny)
    let cost =
      if intoWater: sim.config.moveStaminaWater else: sim.config.moveStaminaLand
    if cost > cog.stamina:
      ## You cannot enter the river on 6 stamina: the move is refused and
      ## degrades to `wait`.
      continue
    cog.x = nx
    cog.y = ny
    cog.stamina = max(0, cog.stamina - cost)
    cog.moveCd =
      if intoWater: sim.config.waterMoveCooldown else: sim.config.moveCooldown
    cog.wading = intoWater
    if intoWater:
      cog.crossings.inc
    sim.cogs[slot] = cog
    if intoWater:
      sim.emit(SimEvent(kind: evCross, seat: slot, x: nx, y: ny,
        stamina: cog.stamina))

# --- step 5 -----------------------------------------------------------------

proc applyOrderOffers(sim: var Sim) =
  for slot in 0 ..< Seats:
    let order = sim.cogs[slot].order
    if not sim.cogs[slot].hasOrder:
      continue
    if not order.hasOfferKey:
      continue                     ## the key being absent leaves it standing
    if order.withdraw:
      if sim.cogs[slot].offer.active:
        sim.cogs[slot].offer = Offer()
        sim.emit(SimEvent(kind: evWithdraw, seat: slot))
      continue
    var offer = order.offer
    offer.active = true
    offer.postedRound = sim.roundOf()
    sim.cogs[slot].offer = offer
    sim.emit(SimEvent(kind: evOffer, seat: slot,
      give: offer.giveFruit, giveN: offer.giveN,
      want: offer.wantFruit, wantN: offer.wantN,
      clamped: order.clamped))

proc stepOfferBook(sim: var Sim) =
  if sim.tick mod sim.config.ticksPerRound == 0:
    sim.applyOrderOffers()
  sim.refreshUnfunded()

# --- step 7 -----------------------------------------------------------------

proc stepEat(sim: var Sim) =
  for slot in 0 ..< Seats:
    var cog = sim.cogs[slot]
    if cog.eatCd > 0 or not cog.hasOrder:
      continue
    let policy = cog.order.eat
    if policy == epNone:
      continue
    let craved = cog.craved()
    var pick: Fruit
    var found = false
    if cog.invOf(craved) > 0:
      pick = craved
      found = true
    elif policy == epAny and cog.invOf(cog.farm) > 0:
      pick = cog.farm
      found = true
    if not found:
      continue
    let isCraved = pick == craved
    cog.addInv(pick, -1)
    cog.hunger = min(HungerMax, cog.hunger +
      (if isCraved: sim.config.craveNutrition else: sim.config.ownNutrition))
    let points =
      if isCraved: sim.config.craveScore else: sim.config.ownScore
    cog.score += points
    if isCraved: cog.cravedEaten.inc else: cog.ownEaten.inc
    cog.eatCd = sim.config.eatCooldown
    sim.cogs[slot] = cog
    sim.emit(SimEvent(kind: evEat, seat: slot, fruit: pick, craved: isCraved,
      hunger: cog.hunger, points: points))

# --- step 8 -----------------------------------------------------------------

proc stepHungerStamina(sim: var Sim) =
  let drain = sim.tick mod sim.config.hungerDrainPeriod == 0 and sim.tick > 0
  for slot in 0 ..< Seats:
    var cog = sim.cogs[slot]
    if drain and cog.hunger > 0:
      cog.hunger.dec
      if cog.hunger == 0 and not cog.starving:
        cog.starving = true
        sim.cogs[slot] = cog
        sim.emit(SimEvent(kind: evStarve, seat: slot))
        sim.beat("starve", seat = slot)
    if cog.hunger > 0:
      cog.starving = false
      if sim.tick mod sim.config.staminaRegenPeriod == 0:
        cog.stamina = min(StaminaMax, cog.stamina + 1)
    else:
      cog.starvingTicks.inc
      cog.stamina = max(0, cog.stamina - sim.config.starveDrain)
    ## `exhausted` fires wherever stamina REACHED 0 this tick — the starvation
    ## drain, a move whose cost was exactly the stamina left, or a harvest at
    ## stamina 1 — because the event table's condition is "stamina reached 0",
    ## and a collapse with no feed row is a collapse the audience never sees.
    let nowExhausted = cog.stamina == 0
    if nowExhausted and not cog.exhausted:
      cog.exhausted = true
      sim.cogs[slot] = cog
      sim.emit(SimEvent(kind: evExhausted, seat: slot))
    cog.exhausted = nowExhausted
    if cog.moveCd > 0: cog.moveCd.dec
    if cog.harvestCd > 0: cog.harvestCd.dec
    if cog.eatCd > 0: cog.eatCd.dec
    sim.cogs[slot] = cog

# --- step 9 -----------------------------------------------------------------

proc recordFrame(sim: var Sim) =
  if not sim.recordFrames:
    return
  var frame = Frame(t: sim.tick)
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    let base = slot * 8
    frame.c[base + 0] = cog.x
    frame.c[base + 1] = cog.y
    frame.c[base + 2] = cog.apples
    frame.c[base + 3] = cog.bananas
    frame.c[base + 4] = cog.hunger
    frame.c[base + 5] = cog.stamina
    frame.c[base + 6] = cog.score
    var flags = 0
    if cog.exhausted: flags = flags or FlagExhausted
    if cog.hunger == 0: flags = flags or FlagStarving
    if cog.tradedThisRound: flags = flags or FlagTraded
    if cog.wading: flags = flags or FlagWading
    frame.c[base + 7] = flags
    let obase = slot * 4
    if cog.offer.active:
      frame.o[obase + 0] = fruitId(cog.offer.giveFruit)
      frame.o[obase + 1] = cog.offer.giveN
      frame.o[obase + 2] = cog.offer.wantN
      frame.o[obase + 3] = (if cog.offer.unfunded: 1 else: 0)
    else:
      frame.o[obase + 0] = -1
      frame.o[obase + 1] = 0
      frame.o[obase + 2] = 0
      frame.o[obase + 3] = 0
  frame.r = newSeq[int](sim.board.trees.len)
  for i, tree in sim.board.trees:
    frame.r[i] = tree.bareFor
  sim.frames.add(frame)
  sim.rate.add([sim.tick, sim.lastRateX100])

# --- the tick ---------------------------------------------------------------

proc stepTick*(sim: var Sim) =
  ## One tick, the nine numbered steps in order. Within a step, seats resolve
  ## in ascending slot order unless the step names another order.
  for slot in 0 ..< Seats:
    sim.cogs[slot].tradedThisTick = false
  sim.stepRegrow()                                   # 1
  var actions: array[Seats, Action]
  for slot in 0 ..< Seats:
    actions[slot] = sim.kernelAction(slot)           # 2
  sim.stepHarvest(actions)                           # 3
  sim.stepMove(actions)                              # 4
  sim.stepOfferBook()                                # 5
  sim.executeTrades()                                # 6
  sim.stepEat()                                      # 7
  sim.stepHungerStamina()                            # 8
  sim.recordFrame()                                  # 9
  sim.tick.inc

proc stepMoveAllForTest*(sim: var Sim, actions: array[Seats, Action]) =
  ## Test hook: run step 4 alone, so the move rules can be asserted without
  ## driving a whole tick through the kernel.
  sim.stepMove(actions)

proc stepMoveForTest*(sim: var Sim, action: Action, slot = 0) =
  var actions: array[Seats, Action]
  for i in 0 ..< Seats:
    actions[i] = aWait
  actions[slot] = action
  sim.stepMove(actions)

proc closeRound*(sim: var Sim) =
  ## Round accounting: the `round` event, the per-seat history row, and the
  ## famine check.
  let round = sim.tick div sim.config.ticksPerRound
  sim.round = round
  sim.roundsPlayed = round
  var
    scores: seq[int]
    hungers: seq[int]
    staminas: seq[int]
    trades = 0
    volume = 0
  for slot in 0 ..< Seats:
    let cog = sim.cogs[slot]
    scores.add(cog.score)
    hungers.add(cog.hunger)
    staminas.add(cog.stamina)
    trades += cog.trades
    volume += cog.volume
    sim.history[slot].add(RoundRow(
      round: round,
      score: cog.score - cog.roundScore0,
      hunger: cog.hunger,
      stamina: cog.stamina,
      trades: cog.trades - cog.roundTrades0,
      harvested: cog.harvested - cog.roundHarvest0,
      eaten: cog.cravedEaten + cog.ownEaten - cog.roundEaten0,
      crossings: cog.crossings - cog.roundCross0,
      marketRate: sim.lastRateX100))
  sim.emit(SimEvent(kind: evRound, round: round, scores: scores,
    hungers: hungers, staminas: staminas, trades: trades, volume: volume,
    rateX100: sim.lastRateX100))
  sim.beat("round", n = round)
  for slot in 0 ..< Seats:
    var cog = sim.cogs[slot]
    cog.roundScore0 = cog.score
    cog.roundTrades0 = cog.trades
    cog.roundHarvest0 = cog.harvested
    cog.roundEaten0 = cog.cravedEaten + cog.ownEaten
    cog.roundCross0 = cog.crossings
    cog.tradedThisRound = false
    sim.cogs[slot] = cog

proc famineReached*(sim: Sim): bool =
  ## Every seat at hunger 0 AND stamina 0 at a round boundary. A market that
  ## starves itself is a COMPLETED game of Fruit Market, not an error.
  for slot in 0 ..< Seats:
    if sim.cogs[slot].hunger > 0 or sim.cogs[slot].stamina > 0:
      return false
  true

proc finish*(sim: var Sim, reason, ending: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  var scores: seq[int]
  for slot in 0 ..< Seats:
    scores.add(sim.cogs[slot].score)
  let terminal = max(0, sim.tick - 1)
  sim.events.add(SimEvent(kind: evEnd, t: terminal, reason: reason,
    ending: ending, scores: scores))
  ## The LAST beat is `gameover` at the final tick, so the scrubber rail's
  ## right edge always reaches the endcard (territory, 2026-08-25).
  sim.beats.add(Beat(t: terminal, kind: "gameover", n: 0, seat: -1))

proc endEarly*(sim: var Sim) =
  ## The play deadline fired between rounds: score the rounds actually played
  ## and settle. `deadline` is admissible — it means the LLM was slow, not that
  ## the game broke.
  sim.finish("deadline", "deadline")

proc forfeit*(sim: var Sim) =
  sim.finish("forfeit", "forfeit")

proc runRound*(sim: var Sim) =
  ## Steps one whole round and closes it. The caller supplies the standing
  ## orders before calling.
  if sim.done:
    return
  for _ in 0 ..< sim.config.ticksPerRound:
    sim.stepTick()
  sim.closeRound()
  if sim.famineReached() and not sim.famineLatched:
    sim.famineLatched = true
    sim.events.add(SimEvent(kind: evFamine, t: max(0, sim.tick - 1)))
    sim.beats.add(Beat(t: max(0, sim.tick - 1), kind: "famine", n: 0, seat: -1))
    sim.finish("complete", "famine")
  elif sim.roundsPlayed >= sim.config.rounds:
    sim.finish("complete", "round_limit")

proc ticksPlayed*(sim: Sim): int = sim.frames.len

proc configJson*(sim: Sim): JsonNode =
  ## Everything the viewer needs to draw the board without a server.
  var water = newJArray()
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      if sim.board.zone[idx(x, y)] == zWater:
        water.add(%*[x, y])
  var trees = newJArray()
  for tree in sim.board.trees:
    trees.add(%*{"fr": $tree.fruit, "x": tree.x, "y": tree.y})
  var stalls = newJArray()
  for id in StallId:
    stalls.add(%*{
      "name": $id, "x": sim.board.stalls[id].x, "y": sim.board.stalls[id].y})
  var spawns = newJArray()
  for cell in spawnCells(sim.farmTypesOf()):
    spawns.add(%*[cell[0], cell[1]])
  %*{
    "variant": sim.config.variantId(),
    "cols": Cols, "rows": Rows, "cell": CellPx,
    "rivers": sim.config.rivers,
    "rounds": sim.config.rounds,
    "ticksPerRound": sim.config.ticksPerRound,
    "water": water,
    "trees": trees,
    "stalls": stalls,
    "spawns": spawns,
    "invCap": sim.config.invCap,
    "hungerMax": HungerMax,
    "hunger0": sim.config.hunger0,
    "hungerDrainPeriod": sim.config.hungerDrainPeriod,
    "craveNutrition": sim.config.craveNutrition,
    "ownNutrition": sim.config.ownNutrition,
    "craveScore": sim.config.craveScore,
    "ownScore": sim.config.ownScore,
    "eatCooldown": sim.config.eatCooldown,
    "staminaMax": StaminaMax,
    "staminaRegenPeriod": sim.config.staminaRegenPeriod,
    "starveDrain": sim.config.starveDrain,
    "moveStaminaLand": sim.config.moveStaminaLand,
    "moveStaminaWater": sim.config.moveStaminaWater,
    "moveCooldown": sim.config.moveCooldown,
    "waterMoveCooldown": sim.config.waterMoveCooldown,
    "harvestCooldownOwn": sim.config.harvestCooldownOwn,
    "harvestCooldownOther": sim.config.harvestCooldownOther,
    "yieldOwn": sim.config.yieldOwn,
    "yieldOther": sim.config.yieldOther,
    "regrowTicks": sim.config.regrowTicks,
    "tradeRadius": sim.config.tradeRadius,
    "viewRadius": sim.config.viewRadius,
    "offerMin": OfferMin,
    "offerMax": sim.config.offerMax
  }
