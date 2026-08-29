## tests/test_global.nim — the SHIPPED renderer's anchors.
##
## Fruit Market draws every board string — the alias plate, the offer bubble,
## the STARVING/EXHAUSTED tag, the hunger bar — into a sprite bitmap in
## `src/fruit_market/global.nim` and anchors it over the cog. `viewer_smoke.mjs
## --strict-text-bounds` cannot see any of that: there is no `fillText` on this
## path, so its `canvas_text.total` is 0 on the real bundle and 0 "is not
## evidence of anything" (checklist 15).
##
## So the anchors are asserted HERE, against the real `buildPacket`: the packet
## is decoded with the sprite protocol's own parser and every object it places
## must lie wholly inside the 1536 x 864 board. This is the cogchemists failure
## (a speech bubble drawn upward from a cog at the top of the arena, every
## body at a negative y, four sentences rendered as four white slivers) made
## into a test.

import std/[json, tables, unittest]

import bitworld/spriteprotocol

import fruit_market/sim, fruit_market/replays, fruit_market/broadcast,
  fruit_market/global

proc boardOf(sim: Sim): ReplayBoard =
  result.cols = Cols
  result.rows = Rows
  result.cell = CellPx
  for i in 0 ..< Cols * Rows:
    result.zone[i] = sim.board.zone[i]
    result.treeAt[i] = sim.board.treeAt[i]
    result.stallAt[i] = sim.board.stallAt[i]
  result.trees = sim.board.trees
  result.stalls = sim.board.stalls

proc placeWorstCase(sim: var Sim, cells: openArray[(int, int)],
    offerN = OfferMax) =
  ## Every seat carries the widest legal offer, is both STARVING and EXHAUSTED
  ## (so the bubble, the tag, the bar and the alias plate all stack over one
  ## cog at once) and stands on the cell handed in.
  for slot in 0 ..< Seats:
    sim.cogs[slot].x = cells[slot][0]
    sim.cogs[slot].y = cells[slot][1]
    sim.cogs[slot].hunger = 0
    sim.cogs[slot].stamina = 0
    sim.cogs[slot].exhausted = true
    sim.cogs[slot].apples = 6
    sim.cogs[slot].bananas = 6
    sim.cogs[slot].offer = Offer(
      active: true,
      giveFruit: (if slot mod 2 == 0: fApple else: fBanana),
      giveN: offerN,
      wantFruit: (if slot mod 2 == 0: fBanana else: fApple),
      wantN: offerN,
      unfunded: slot mod 3 == 0)

proc anchorsInsideBoard(sim: Sim): tuple[objects: int, worst: string] =
  ## Builds ONE presentation frame with the shipped emitter and decodes it.
  var state = initViewerState()
  let board = sim.boardOf()
  var bare: seq[int]
  for tree in sim.board.trees:
    bare.add(tree.bareFor)
  let view = chromeViewOfSim(sim, newJArray(), false)
  var sizes = initTable[int, (int, int)]()
  var objects = 0
  var worst = ""
  ## Eight passes: the terrain bake is dripped two bands per frame, and every
  ## overlay sprite is re-emitted whenever its label changes.
  for pass in 0 ..< 5:
    let packet = state.buildPacket(board, view, bare, "{}")
    for message in parseSpritePacket(packet):
      case message.kind
      of spkSprite:
        sizes[message.sprite.id] = (message.sprite.width, message.sprite.height)
      of spkObject:
        let obj = message.objectDef
        if not sizes.hasKey(obj.spriteId):
          worst = "object " & $obj.id & " uses undefined sprite " & $obj.spriteId
          continue
        let (w, h) = sizes[obj.spriteId]
        objects.inc
        if obj.x < 0 or obj.y < 0 or obj.x + w > BoardW or obj.y + h > BoardH:
          worst = "object " & $obj.id & " sprite " & $obj.spriteId & " at (" &
            $obj.x & "," & $obj.y & ") size " & $w & "x" & $h &
            " leaves the " & $BoardW & "x" & $BoardH & " board"
      else:
        discard
  (objects, worst)

proc bench(): Sim =
  var config = defaultGameConfig()
  config.seed = 3
  initSim(config)

suite "the transport keys the page sends":
  test "+ and - walk the same speed ladder the number keys select from":
    var sim = bench()
    sim.setRoundOrders(default(array[Seats, Order]))
    sim.stepTick()
    let replay = parseReplay($replayJson(sim, sim.resultsJson()))
    var state = initViewerState()
    check state.speed == 1
    state.commands = @['+']
    state.advanceReplay(replay)
    check state.speed == 2
    state.commands = @['+', '+']
    state.advanceReplay(replay)
    check state.speed == 4
    state.commands = @['-']
    state.advanceReplay(replay)
    check state.speed == 3
    ## The ladder tops out where PlaybackSpeeds ends and bottoms out one rung
    ## BELOW it, on the replay-only 1/2x sentinel.
    state.commands = @['+', '+', '+', '+', '+']
    state.advanceReplay(replay)
    check state.speed == PlaybackSpeeds[^1]
    state.commands = @['-', '-', '-', '-', '-', '-', '-']
    state.advanceReplay(replay)
    check state.speed == ReplayHalfSpeed
    state.commands = @['+']
    state.advanceReplay(replay)
    check state.speed == PlaybackSpeeds[0]
    ## And a numeric key still selects directly.
    state.commands = @['8']
    state.advanceReplay(replay)
    check state.speed == 8

  test "half speed is a replay-only crawl":
    ## The fleet-wide 1/2x replay speed: command '5' selects the
    ## ReplayHalfSpeed sentinel, the chrome shows 0.5, and the playhead
    ## advances one frame every OTHER presentation frame (halfPhase parity).
    var sim = bench()
    sim.setRoundOrders(default(array[Seats, Order]))
    for tick in 0 ..< 20:
      sim.stepTick()
    let replay = parseReplay($replayJson(sim, sim.resultsJson()))
    var state = initViewerState()
    state.commands = @['5']
    state.advanceReplay(replay)
    check state.speed == ReplayHalfSpeed
    check state.displaySpeed() == 0.5
    ## Ten frames from the start advance the playhead five ticks.
    state.index = 0
    state.playing = true
    state.halfPhase = false
    var advanced = 0
    for frame in 0 ..< 10:
      let before = state.index
      state.advanceReplay(replay)
      if state.index != before:
        advanced.inc
      check state.index - before <= 1
    check advanced == 5
    ## '-' from 1x lands on 1/2x, the floor; '+' climbs back out onto 1x.
    state.commands = @['1', '-']
    state.advanceReplay(replay)
    check state.speed == ReplayHalfSpeed
    state.commands = @['-']
    state.advanceReplay(replay)
    check state.speed == ReplayHalfSpeed
    state.commands = @['+']
    state.advanceReplay(replay)
    check state.speed == PlaybackSpeeds[0]
    check state.displaySpeed() == 1.0

suite "every drawn overlay fits the board":
  test "a full bubble, a tag, a bar and an alias on every seat, at the edges":
    ## The four extreme legal rows and columns: a cog at the top of the arena
    ## is where the bubble stack runs out of room upward, and a cog at either
    ## end of a row is where a centred plate runs off sideways.
    const Corners = [
      [(1, 1), (2, 1), (3, 1), (4, 1), (27, 1), (28, 1), (29, 1), (30, 1)],
      [(1, 16), (2, 16), (3, 16), (4, 16), (27, 16), (28, 16), (29, 16),
       (30, 16)],
      [(1, 1), (1, 4), (1, 8), (1, 12), (30, 1), (30, 4), (30, 8), (30, 12)],
      [(8, 8), (9, 8), (14, 8), (15, 8), (17, 9), (18, 9), (23, 9), (24, 9)]
    ]
    for cells in Corners:
      var sim = bench()
      sim.placeWorstCase(cells)
      let (objects, worst) = sim.anchorsInsideBoard()
      check objects > Seats * 4       ## cog + bar + alias + bubble + tag, x8
      check worst == ""

  test "the widest offer the schema allows still fits":
    ## `offerMax` is bounded at 12 by the config schema, so two-digit
    ## quantities on both sides are the widest bubble this game can draw.
    var config = defaultGameConfig()
    config.seed = 3
    config.offerMax = 12
    var sim = initSim(config)
    sim.placeWorstCase(
      [(1, 1), (30, 1), (1, 16), (30, 16), (1, 8), (30, 8), (16, 1), (16, 16)],
      offerN = 12)
    let (objects, worst) = sim.anchorsInsideBoard()
    check objects > Seats * 4
    check worst == ""

  test "a healthy board with no offers still places every object inside":
    var sim = bench()
    let (objects, worst) = sim.anchorsInsideBoard()
    check objects > 0
    check worst == ""
