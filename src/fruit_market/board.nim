## The fixed 32 x 18 board: walls, the two concentric rivers, the 48 trees, the
## four stalls, the eight spawns, and the weighted Dijkstra the kernel walks.
##
## Heavily reduced fork of coworld-ctf `src/ctf/arena.nim`. The terrain
## generator, `mapSpec`, symmetry, the validators, the pixel queries and
## `map_pool` are DELETED — Fruit Market has one authored board per variant and
## the variants only change constants.

import std/[algorithm]

import ./sim_types

const
  AppleTreeCells*: seq[array[2, int]] = @[
    [3, 2], [6, 2], [9, 2], [12, 2], [15, 2], [18, 2], [21, 2], [24, 2],
    [27, 2],
    [3, 15], [6, 15], [9, 15], [12, 15], [15, 15], [18, 15], [21, 15],
    [24, 15], [27, 15],
    [2, 5], [2, 8], [2, 11],
    [29, 5], [29, 8], [29, 11]]

  BananaTreeCells*: seq[array[2, int]] = @[
    ## The island is x 7..24, y 7..10. The design note's first cut put trees at
    ## x == 12 and x == 19 in EVERY island row, which walls the island into
    ## three pieces (tree cells are impassable) and strands the four corners —
    ## tests/test_map.nim's zone-connectivity assertion catches it. The 24 trees
    ## therefore live in the two OUTER island rows, leaving rows 8 and 9 as the
    ## clear corridor that keeps the grove one connected place.
    [8, 7], [9, 7], [11, 7], [12, 7], [14, 7], [15, 7],
    [17, 7], [18, 7], [20, 7], [21, 7], [23, 7], [24, 7],
    [8, 10], [9, 10], [11, 10], [12, 10], [14, 10], [15, 10],
    [17, 10], [18, 10], [20, 10], [21, 10], [23, 10], [24, 10]]

  StallCells*: array[StallId, array[2, int]] = [
    [16, 4],   # north
    [27, 8],   # east
    [16, 13],  # south
    [4, 8]     # west
  ]

  AppleSpawns*: array[4, array[2, int]] = [[4, 1], [11, 1], [20, 1], [27, 1]]
  BananaSpawns*: array[4, array[2, int]] = [[8, 8], [14, 8], [17, 9], [23, 9]]

  LandCost* = 1
  WaterCost* = 8
    ## Dijkstra weights. A route only crosses a river when the detour is
    ## genuinely longer — for `trek` it always is.

type
  Board* = object
    ## One resolved board. `rivers` 0 turns every water cell into land; the
    ## tree lists never change.
    rivers*: int
    zone*: array[Cols * Rows, Zone]
    treeAt*: array[Cols * Rows, int]   ## index into `trees`, or -1
    stallAt*: array[Cols * Rows, int]  ## StallId ord, or -1
    trees*: seq[Tree]
    stalls*: array[StallId, Stall]

proc inset*(x, y: int): int =
  ## d(x,y) — the rectangular inset of an interior cell, 0..7.
  min(min(x - 1, 30 - x), min(y - 1, 16 - y))

proc idx*(x, y: int): int {.inline.} = y * Cols + x

proc onBoard*(x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < Cols and y < Rows

proc isWallCell*(x, y: int): bool =
  x == 0 or y == 0 or x == Cols - 1 or y == Rows - 1

proc zoneFor*(x, y, rivers: int): Zone =
  if isWallCell(x, y):
    return zWall
  let d = inset(x, y)
  if rivers >= 2 and (d == 2 or d == 5):
    return zWater
  if d <= 2: zOrchard
  elif d <= 5: zMarket
  else: zIsland

proc initBoard*(rivers: int): Board =
  ## Builds the authored board. Asserted here AND in tests/test_map.nim.
  result.rivers = rivers
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      result.zone[idx(x, y)] = zoneFor(x, y, rivers)
      result.treeAt[idx(x, y)] = -1
      result.stallAt[idx(x, y)] = -1
  for cell in AppleTreeCells:
    result.trees.add(Tree(x: cell[0], y: cell[1], fruit: fApple, bareFor: 0))
  for cell in BananaTreeCells:
    result.trees.add(Tree(x: cell[0], y: cell[1], fruit: fBanana, bareFor: 0))
  doAssert result.trees.len == 48, "the board carries 24 + 24 trees"
  for i, tree in result.trees:
    let at = idx(tree.x, tree.y)
    doAssert result.treeAt[at] == -1, "duplicate tree cell"
    doAssert result.zone[at] notin {zWall, zWater}, "tree on wall or water"
    result.treeAt[at] = i
  for id in StallId:
    let cell = StallCells[id]
    result.stalls[id] = Stall(id: id, x: cell[0], y: cell[1])
    let at = idx(cell[0], cell[1])
    doAssert result.zone[at] == zMarket, "stall outside the market ring"
    doAssert result.treeAt[at] == -1, "stall on a tree"
    result.stallAt[at] = ord(id)

proc zoneAt*(board: Board, x, y: int): Zone {.inline.} =
  if not onBoard(x, y): zWall else: board.zone[idx(x, y)]

proc isWater*(board: Board, x, y: int): bool {.inline.} =
  board.zoneAt(x, y) == zWater

proc isTree*(board: Board, x, y: int): bool {.inline.} =
  onBoard(x, y) and board.treeAt[idx(x, y)] >= 0

proc passable*(board: Board, x, y: int): bool {.inline.} =
  ## Walls and tree cells are impassable; water is passable at a stamina cost.
  onBoard(x, y) and board.zoneAt(x, y) != zWall and not board.isTree(x, y)

proc waterCellCount*(board: Board): int =
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      if board.zone[idx(x, y)] == zWater:
        inc result

proc spawnCells*(farmTypes: openArray[Fruit]): array[Seats, array[2, int]] =
  ## Apple farmers spawn in ascending slot order among apple-type seats, then
  ## banana farmers likewise. Every cell is land, tree-free and stall-free.
  var appleNext = 0
  var bananaNext = 0
  for slot in 0 ..< Seats:
    if farmTypes[slot] == fApple:
      result[slot] = AppleSpawns[appleNext]
      inc appleNext
    else:
      result[slot] = BananaSpawns[bananaNext]
      inc bananaNext

const
  StepDx*: array[4, int] = [0, 1, 0, -1]   ## N, E, S, W — the expansion order
  StepDy*: array[4, int] = [-1, 0, 1, 0]
  StepAction*: array[4, Action] = [aMoveN, aMoveE, aMoveS, aMoveW]

type
  PathField* = object
    ## A weighted-distance field from one origin over the whole board. Ties are
    ## resolved by the N, E, S, W expansion order, so paths are unique and
    ## deterministic.
    dist*: array[Cols * Rows, int]
    fromDir*: array[Cols * Rows, int]   ## direction index taken INTO this cell

const Unreached* = high(int) div 4

proc dijkstra*(board: Board, sx, sy: int): PathField =
  ## Cost 1 over land, `WaterCost` into water. Other cogs are not obstacles for
  ## path PLANNING, only for the move itself.
  for i in 0 ..< Cols * Rows:
    result.dist[i] = Unreached
    result.fromDir[i] = -1
  if not board.passable(sx, sy):
    return
  result.dist[idx(sx, sy)] = 0
  ## The board is 576 cells with costs in 1..8, so a bucketed sweep over a
  ## bounded frontier is both simpler and faster than a heap, and it is
  ## deterministic without a tie-break comparator.
  var frontier = @[idx(sx, sy)]
  while frontier.len > 0:
    var best = 0
    for i in 1 ..< frontier.len:
      if result.dist[frontier[i]] < result.dist[frontier[best]]:
        best = i
    let at = frontier[best]
    frontier.del(best)
    let
      cx = at mod Cols
      cy = at div Cols
      base = result.dist[at]
    for dir in 0 ..< 4:
      let
        nx = cx + StepDx[dir]
        ny = cy + StepDy[dir]
      if not board.passable(nx, ny):
        continue
      let
        step = if board.isWater(nx, ny): WaterCost else: LandCost
        cost = base + step
        ni = idx(nx, ny)
      if cost < result.dist[ni]:
        result.dist[ni] = cost
        result.fromDir[ni] = dir
        frontier.add(ni)

proc firstStep*(field: PathField, sx, sy, tx, ty: int): Action =
  ## The first grid action on the unique shortest path from the field's origin
  ## to (tx, ty), or `aWait` when there is no path or we are already there.
  if not onBoard(tx, ty) or field.dist[idx(tx, ty)] >= Unreached:
    return aWait
  var
    cx = tx
    cy = ty
  if cx == sx and cy == sy:
    return aWait
  while true:
    let dir = field.fromDir[idx(cx, cy)]
    if dir < 0:
      return aWait
    let
      px = cx - StepDx[dir]
      py = cy - StepDy[dir]
    if px == sx and py == sy:
      return StepAction[dir]
    cx = px
    cy = py

proc reachableWithoutWater*(board: Board, sx, sy: int): seq[bool] =
  ## Flood fill over LAND only — the connectivity the map test asserts.
  result = newSeq[bool](Cols * Rows)
  if not board.passable(sx, sy) or board.isWater(sx, sy):
    return
  var stack = @[idx(sx, sy)]
  result[idx(sx, sy)] = true
  while stack.len > 0:
    let at = stack.pop()
    let
      cx = at mod Cols
      cy = at div Cols
    for dir in 0 ..< 4:
      let
        nx = cx + StepDx[dir]
        ny = cy + StepDy[dir]
      if not board.passable(nx, ny) or board.isWater(nx, ny):
        continue
      let ni = idx(nx, ny)
      if not result[ni]:
        result[ni] = true
        stack.add(ni)

proc zoneCells*(board: Board, zone: Zone): seq[int] =
  for i in 0 ..< Cols * Rows:
    if board.zone[i] == zone and board.treeAt[i] < 0:
      result.add(i)

proc sortedStalls*(): seq[StallId] =
  ## north, east, south, west — the canonical tie-break order.
  result = @[stNorth, stEast, stSouth, stWest]
  result.sort(proc (a, b: StallId): int = cmp(ord(a), ord(b)))
