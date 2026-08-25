## tests/test_map.nim — the board.
##
## The authored 32 x 18 grid: zoning by d(x,y), the two concentric rivers, the
## 48 trees, the four stalls, the eight spawns, and the connectivity the whole
## geography argument rests on.

import std/[sets, unittest]

import fruit_market/sim

suite "the board":
  let board = initBoard(2)

  test "d(x,y) zones the interior into four belts":
    var counts: array[Zone, int]
    for y in 0 ..< Rows:
      for x in 0 ..< Cols:
        counts[board.zoneAt(x, y)].inc
    ## 30 x 16 interior: orchard d in {0,1} = 88 + 80, market d in {3,4} =
    ## 64 + 56, island d in {6,7} = 40 + 32.
    check counts[zOrchard] == 168
    check counts[zMarket] == 120
    check counts[zIsland] == 72
    check counts[zWall] == Cols * Rows - 30 * 16

  test "the two rivers are one cell wide, at d == 2 and d == 5":
    var outer, inner = 0
    for y in 0 ..< Rows:
      for x in 0 ..< Cols:
        if board.zoneAt(x, y) != zWater:
          continue
        case inset(x, y)
        of 2: outer.inc
        of 5: inner.inc
        else: check false
    ## The perimeter of the inset rectangle is 88 - 8d cells.
    check outer == 72
    check inner == 48
    check board.waterCellCount() == 120

  test "24 apple and 24 banana trees, at the authored cells, no duplicates":
    var apples, bananas = 0
    var seen = initHashSet[int]()
    for tree in board.trees:
      check not seen.containsOrIncl(idx(tree.x, tree.y))
      check board.zoneAt(tree.x, tree.y) notin {zWall, zWater}
      check board.stallAt[idx(tree.x, tree.y)] == -1
      if tree.fruit == fApple:
        apples.inc
        check inset(tree.x, tree.y) == 1
      else:
        bananas.inc
        check board.zoneAt(tree.x, tree.y) == zIsland
    check apples == 24
    check bananas == 24
    check board.trees.len == 48

  test "the four stalls are land in the market ring":
    for id in StallId:
      let stall = board.stalls[id]
      check board.zoneAt(stall.x, stall.y) == zMarket
      check not board.isTree(stall.x, stall.y)
      check board.passable(stall.x, stall.y)
    check board.stalls[stNorth].x == 16 and board.stalls[stNorth].y == 4
    check board.stalls[stSouth].x == 16 and board.stalls[stSouth].y == 13
    check board.stalls[stWest].x == 4 and board.stalls[stWest].y == 8
    check board.stalls[stEast].x == 27 and board.stalls[stEast].y == 8

  test "the eight spawn cells are free land, four per grove":
    var farmTypes: array[Seats, Fruit]
    for slot in 0 ..< Seats:
      farmTypes[slot] = if slot < 4: fApple else: fBanana
    let spawns = spawnCells(farmTypes)
    var seen = initHashSet[int]()
    for slot in 0 ..< Seats:
      let cell = spawns[slot]
      check not seen.containsOrIncl(idx(cell[0], cell[1]))
      check board.passable(cell[0], cell[1])
      check not board.isWater(cell[0], cell[1])
      check board.stallAt[idx(cell[0], cell[1])] == -1
      check board.zoneAt(cell[0], cell[1]) ==
        (if farmTypes[slot] == fApple: zOrchard else: zIsland)

  test "every land cell of a zone reaches every other without entering water":
    for zone in [zOrchard, zMarket, zIsland]:
      let cells = board.zoneCells(zone)
      check cells.len > 0
      let reach = board.reachableWithoutWater(cells[0] mod Cols, cells[0] div Cols)
      for cell in cells:
        check reach[cell]

  test "the market ring is one crossing from each grove, the groves two apart":
    ## Weighted Dijkstra with cost(water) = 8: a market <-> grove path pays one
    ## crossing and a grove <-> grove path pays two, so the second is at least
    ## one whole toll more expensive however the walk is routed.
    let stall = board.stalls[stNorth]
    let fromStall = dijkstra(board, stall.x, stall.y)
    var nearestApple, nearestBanana = Unreached
    for tree in board.trees:
      for dir in 0 ..< 4:
        let cell = idx(tree.x + StepDx[dir], tree.y + StepDy[dir])
        if not onBoard(tree.x + StepDx[dir], tree.y + StepDy[dir]):
          continue
        if fromStall.dist[cell] >= Unreached:
          continue
        if tree.fruit == fApple:
          nearestApple = min(nearestApple, fromStall.dist[cell])
        else:
          nearestBanana = min(nearestBanana, fromStall.dist[cell])
    check nearestApple < Unreached
    check nearestBanana < Unreached
    check nearestApple >= WaterCost
    check nearestBanana >= WaterCost

    let appleTree = board.trees[0]
    let fromApple = dijkstra(board, appleTree.x, appleTree.y - 1)
    var grove2 = Unreached
    for tree in board.trees:
      if tree.fruit != fBanana:
        continue
      for dir in 0 ..< 4:
        let nx = tree.x + StepDx[dir]
        let ny = tree.y + StepDy[dir]
        if onBoard(nx, ny):
          grove2 = min(grove2, fromApple.dist[idx(nx, ny)])
    check grove2 >= 2 * WaterCost

  test "rivers: 0 turns every water cell into land, trees unchanged":
    let open = initBoard(0)
    check open.waterCellCount() == 0
    check open.trees.len == board.trees.len
    for i, tree in open.trees:
      check tree.x == board.trees[i].x
      check tree.y == board.trees[i].y
      check tree.fruit == board.trees[i].fruit
    ## Every interior land cell is now one connected region.
    let reach = open.reachableWithoutWater(1, 1)
    for y in 1 ..< Rows - 1:
      for x in 1 ..< Cols - 1:
        if open.passable(x, y):
          check reach[idx(x, y)]
