## The courier kernel: a standing order plus the current tick's state becomes
## one grid action.
##
## No LLM can emit 720 actions per seat, so once per ROUND each seat submits a
## standing order and this deterministic kernel turns it into the per-tick
## action stream: 96 LLM calls per episode instead of 5 760.

import ./sim_types, ./sim_config, ./board, ./sim_state

proc adjacentRipeTree*(sim: Sim, x, y: int, fruit: Fruit): int =
  ## The first ripe adjacent tree of `fruit` in N, E, S, W order, or -1.
  for dir in 0 ..< 4:
    let
      nx = x + StepDx[dir]
      ny = y + StepDy[dir]
    if not onBoard(nx, ny):
      continue
    let at = sim.board.treeAt[idx(nx, ny)]
    if at >= 0 and sim.board.trees[at].fruit == fruit and
        sim.board.trees[at].bareFor == 0:
      return at
  -1

proc adjacentAnyRipeTree*(sim: Sim, x, y: int): int =
  ## The first ripe adjacent tree of ANY fruit, N, E, S, W. Step 3 of the tick
  ## harvests whatever is there; the kernel decides whether to try.
  for dir in 0 ..< 4:
    let
      nx = x + StepDx[dir]
      ny = y + StepDy[dir]
    if not onBoard(nx, ny):
      continue
    let at = sim.board.treeAt[idx(nx, ny)]
    if at >= 0 and sim.board.trees[at].bareFor == 0:
      return at
  -1

proc treeApproachCells(sim: Sim, treeIndex: int): seq[int] =
  let tree = sim.board.trees[treeIndex]
  for dir in 0 ..< 4:
    let
      nx = tree.x + StepDx[dir]
      ny = tree.y + StepDy[dir]
    if sim.board.passable(nx, ny):
      result.add(idx(nx, ny))

proc occupiedByOther(sim: Sim, slot, cell: int): bool =
  for other in 0 ..< Seats:
    if other == slot:
      continue
    if idx(sim.cogs[other].x, sim.cogs[other].y) == cell:
      return true
  false

proc nearestTarget(field: PathField, targets: openArray[int]): int =
  ## The reachable target with the smallest weighted distance; ties go to the
  ## lowest cell index, so the choice is unique.
  result = -1
  var best = Unreached
  for cell in targets:
    let d = field.dist[cell]
    if d < best or (d == best and result >= 0 and cell < result):
      best = d
      result = cell
  if best >= Unreached:
    result = -1

proc nearestFreeTarget(sim: Sim, slot: int, field: PathField,
    targets: openArray[int]): int =
  ## The nearest target that is not already held by another cog. Other cogs are
  ## not obstacles for path PLANNING — but a destination somebody is standing
  ## on is not a destination, and a kernel that keeps walking at it stalls
  ## there for the rest of the round.
  var free: seq[int]
  for cell in targets:
    if not sim.occupiedByOther(slot, cell):
      free.add(cell)
  result = nearestTarget(field, free)
  if result < 0:
    result = nearestTarget(field, targets)

proc groveZoneFor*(fruit: Fruit): Zone =
  if fruit == fApple: zOrchard else: zIsland

proc harvestTargets(sim: Sim, fruit: Fruit, zone: Zone, ripeOnly: bool): seq[int] =
  for i, tree in sim.board.trees:
    if tree.fruit != fruit:
      continue
    if ripeOnly and tree.bareFor != 0:
      continue
    if zone != zWall and sim.board.zoneAt(tree.x, tree.y) != zone:
      continue
    for cell in sim.treeApproachCells(i):
      result.add(cell)

proc stallTargets(sim: Sim, stall: StallId): seq[int] =
  let s = sim.board.stalls[stall]
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      let
        nx = s.x + dx
        ny = s.y + dy
      if sim.board.passable(nx, ny):
        result.add(idx(nx, ny))

proc bestStall*(sim: Sim, field: PathField): StallId =
  ## The stall with the shortest path; ties north, east, south, west.
  result = stNorth
  var best = Unreached + 1
  for id in StallId:
    let cells = sim.stallTargets(id)
    var d = Unreached
    for cell in cells:
      d = min(d, field.dist[cell])
    if d < best:
      best = d
      result = id

proc stallDistance*(sim: Sim, field: PathField, id: StallId): int =
  var d = Unreached
  for cell in sim.stallTargets(id):
    d = min(d, field.dist[cell])
  if d >= Unreached: -1 else: d

proc kernelAction*(sim: Sim, slot: int): Action =
  ## Step 2 of the tick. A cog whose relevant cooldown is still running, or
  ## which is exhausted, emits `wait` instead of the derived action.
  let cog = sim.cogs[slot]
  if not cog.hasOrder:
    return aWait
  let order = cog.order
  if order.job == jRest:
    return aWait

  let field = dijkstra(sim.board, cog.x, cog.y)
  var
    targets: seq[int]
    harvestFruit = cog.farm
    wantHarvest = false

  case order.job
  of jRest:
    return aWait
  of jMarket:
    let stall =
      if order.hasStall: order.stall else: sim.bestStall(field)
    targets = sim.stallTargets(stall)
  of jHarvest:
    harvestFruit = if order.hasFruit: order.fruit else: cog.farm
    wantHarvest = true
    targets = sim.harvestTargets(harvestFruit, zWall, true)
    if targets.len == 0:
      ## No tree of that fruit is ripe anywhere: walk to the nearest tree of
      ## that fruit and wait beside it.
      targets = sim.harvestTargets(harvestFruit, zWall, false)
      wantHarvest = false
  of jTrek:
    let farZone = groveZoneFor(other(cog.farm))
    harvestFruit = if order.hasFruit: order.fruit else: other(cog.farm)
    wantHarvest = true
    targets = sim.harvestTargets(harvestFruit, farZone, true)
    if targets.len == 0:
      targets = sim.harvestTargets(other(cog.farm), farZone, true)
      harvestFruit = other(cog.farm)
    if targets.len == 0:
      targets = sim.harvestTargets(other(cog.farm), farZone, false)
      wantHarvest = false

  let here = idx(cog.x, cog.y)
  var standing = false
  for cell in targets:
    if cell == here:
      standing = true
      break

  if standing:
    if wantHarvest and sim.adjacentRipeTree(cog.x, cog.y, harvestFruit) >= 0:
      if cog.exhausted or cog.harvestCd > 0:
        return aWait
      return aHarvest
    return aWait

  let target = sim.nearestFreeTarget(slot, field, targets)
  if target < 0:
    return aWait
  var step = field.firstStep(cog.x, cog.y, target mod Cols, target div Cols)
  if step == aWait:
    return aWait
  ## A step into a cell another cog is standing in is refused in step 4 and
  ## would leave this cog stalled against it every tick, so slide around it:
  ## take the first legal neighbour that does not increase the distance.
  block sidestep:
    let dir =
      case step
      of aMoveN: 0
      of aMoveE: 1
      of aMoveS: 2
      else: 3
    let ahead = idx(cog.x + StepDx[dir], cog.y + StepDy[dir])
    if not sim.occupiedByOther(slot, ahead):
      break sidestep
    let here = field.dist[idx(cog.x, cog.y)]
    for alt in 0 ..< 4:
      let
        nx = cog.x + StepDx[alt]
        ny = cog.y + StepDy[alt]
      if not sim.board.passable(nx, ny):
        continue
      if sim.occupiedByOther(slot, idx(nx, ny)):
        continue
      if sim.board.isWater(nx, ny):
        continue
      if field.dist[idx(nx, ny)] <= here + LandCost:
        step = StepAction[alt]
        break sidestep
    return aWait
  if cog.exhausted or cog.moveCd > 0:
    return aWait
  ## A move whose stamina cost exceeds the cog's stamina is refused in step 4;
  ## the kernel still names it so the refusal is visible as a `wait`.
  step
