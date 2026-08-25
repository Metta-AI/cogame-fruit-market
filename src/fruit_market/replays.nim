## The replay file (`fruit-market.replay.v1`) — STRICT UTF-8 JSON, one document.
##
## Rewritten from coworld-ctf's `replays.nim` + `replay_runtime.nim`: Fruit
## Market records STATE, not inputs, so playback never re-simulates, a seek is
## an array index, and there is no native/wasm divergence to chase — which is
## also why `#mmwarn` and a mismatch tick are dropped.

import std/[json, strutils]

import ./sim_types, ./sim_config, ./board, ./events, ./sim_state, ./sim

const ReplayProtocol* = "fruit-market.replay.v1"

type
  ReplayBoard* = object
    ## The board geometry the viewer draws, straight out of the replay bytes.
    cols*, rows*, cell*: int
    zone*: array[Cols * Rows, Zone]
    treeAt*: array[Cols * Rows, int]
    stallAt*: array[Cols * Rows, int]
    trees*: seq[Tree]
    stalls*: array[StallId, Stall]

  Replay* = object
    protocol*: string
    gameVersion*: string
    seed*: int
    variant*: string
    rounds*, ticksPerRound*: int
    names*: array[Seats, string]
    policyNames*: array[Seats, string]
    colors*: array[Seats, string]
    farmTypes*: array[Seats, Fruit]
    board*: ReplayBoard
    config*: JsonNode
    frames*: seq[Frame]
    rate*: seq[array[2, int]]
    beats*: seq[Beat]
    events*: JsonNode
    results*: JsonNode

proc replayJson*(sim: Sim, results: JsonNode): JsonNode =
  var
    names = newJArray()
    policyNames = newJArray()
    colors = newJArray()
    farmTypes = newJArray()
  for slot in 0 ..< Seats:
    names.add(%sim.aliases[slot])
    policyNames.add(%sim.policyNames[slot])
    colors.add(%CogColorNames[slot])
    farmTypes.add(%($sim.cogs[slot].farm))
  var frames = newJArray()
  for frame in sim.frames:
    var c = newJArray()
    for value in frame.c:
      c.add(%value)
    var o = newJArray()
    for value in frame.o:
      o.add(%value)
    var r = newJArray()
    for value in frame.r:
      r.add(%value)
    frames.add(%*{"t": frame.t, "c": c, "o": o, "r": r})
  var rate = newJArray()
  for row in sim.rate:
    rate.add(%*[row[0], row[1]])
  var beats = newJArray()
  for item in sim.beats:
    var node = %*{"t": item.t, "k": item.kind}
    if item.kind == "round":
      node["n"] = %item.n
    if item.seat >= 0:
      node["seat"] = %item.seat
    beats.add(node)
  %*{
    "protocol": ReplayProtocol,
    "game": "fruit-market",
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "names": names,
    "policyNames": policyNames,
    "colors": colors,
    "farmTypes": farmTypes,
    "config": sim.configJson(),
    "frames": frames,
    "series": {"rate": rate},
    "beats": beats,
    "events": eventsJson(sim.events),
    "results": results
  }

proc parseReplay*(bytes: string): Replay =
  ## Parses the recorded document and hydrates the frame array. Raises with a
  ## named reason so the viewer can report it through `data-replay-error`.
  let node = parseJson(bytes)
  if node.kind != JObject:
    raise newException(FruitMarketError, "replay is not a JSON object")
  result.protocol = node{"protocol"}.getStr()
  if result.protocol != ReplayProtocol:
    raise newException(FruitMarketError,
      "unexpected replay protocol: " & result.protocol)
  result.gameVersion = node{"gameVersion"}.getStr()
  result.seed = node{"seed"}.getInt()
  let config = node{"config"}
  if config.isNil or config.kind != JObject:
    raise newException(FruitMarketError, "replay carries no config block")
  result.config = config
  result.variant = config{"variant"}.getStr("concentric-rivers")
  result.rounds = config{"rounds"}.getInt(Rounds)
  result.ticksPerRound = config{"ticksPerRound"}.getInt(TicksPerRound)
  result.board.cols = config{"cols"}.getInt(Cols)
  result.board.rows = config{"rows"}.getInt(Rows)
  result.board.cell = config{"cell"}.getInt(CellPx)
  if result.board.cols != Cols or result.board.rows != Rows:
    raise newException(FruitMarketError, "replay board is not 32 x 18")

  for slot in 0 ..< Seats:
    result.names[slot] = CogAliases[slot]
    result.policyNames[slot] = CogAliases[slot]
    result.colors[slot] = CogColorNames[slot]
    result.farmTypes[slot] = fApple
  var slot = 0
  for item in node{"names"}:
    if slot < Seats: result.names[slot] = item.getStr()
    inc slot
  slot = 0
  for item in node{"policyNames"}:
    if slot < Seats: result.policyNames[slot] = item.getStr()
    inc slot
  slot = 0
  for item in node{"colors"}:
    if slot < Seats: result.colors[slot] = item.getStr()
    inc slot
  slot = 0
  for item in node{"farmTypes"}:
    if slot < Seats:
      result.farmTypes[slot] =
        if item.getStr() == "banana": fBanana else: fApple
    inc slot

  ## Terrain comes from the recorded water list, so a variant that turned the
  ## rivers into land draws exactly as it played.
  for i in 0 ..< Cols * Rows:
    let
      x = i mod Cols
      y = i div Cols
    result.board.zone[i] =
      if isWallCell(x, y): zWall
      else:
        let d = inset(x, y)
        if d <= 2: zOrchard elif d <= 5: zMarket else: zIsland
    result.board.treeAt[i] = -1
    result.board.stallAt[i] = -1
  for cell in config{"water"}:
    let
      x = cell[0].getInt()
      y = cell[1].getInt()
    if onBoard(x, y):
      result.board.zone[idx(x, y)] = zWater
  for tree in config{"trees"}:
    let item = Tree(
      x: tree{"x"}.getInt(),
      y: tree{"y"}.getInt(),
      fruit: (if tree{"fr"}.getStr() == "banana": fBanana else: fApple))
    result.board.treeAt[idx(item.x, item.y)] = result.board.trees.len
    result.board.trees.add(item)
  for id in StallId:
    result.board.stalls[id] = Stall(id: id, x: StallCells[id][0],
      y: StallCells[id][1])
  for stall in config{"stalls"}:
    for id in StallId:
      if stall{"name"}.getStr() == $id:
        result.board.stalls[id] =
          Stall(id: id, x: stall{"x"}.getInt(), y: stall{"y"}.getInt())
  for id in StallId:
    result.board.stallAt[
      idx(result.board.stalls[id].x, result.board.stalls[id].y)] = ord(id)

  let frames = node{"frames"}
  if frames.isNil or frames.kind != JArray or frames.len == 0:
    raise newException(FruitMarketError, "replay carries no frames")
  for item in frames:
    var frame = Frame(t: item{"t"}.getInt())
    var i = 0
    for value in item{"c"}:
      if i < frame.c.len: frame.c[i] = value.getInt()
      inc i
    i = 0
    for value in item{"o"}:
      if i < frame.o.len: frame.o[i] = value.getInt()
      inc i
    frame.r = newSeq[int](result.board.trees.len)
    i = 0
    for value in item{"r"}:
      if i < frame.r.len: frame.r[i] = value.getInt()
      inc i
    result.frames.add(frame)

  for row in node{"series"}{"rate"}:
    result.rate.add([row[0].getInt(), row[1].getInt()])
  for item in node{"beats"}:
    result.beats.add(Beat(
      t: item{"t"}.getInt(),
      kind: item{"k"}.getStr(),
      n: item{"n"}.getInt(),
      seat: item{"seat"}.getInt(-1)))
  result.events = node{"events"}
  if result.events.isNil:
    result.events = newJArray()
  result.results = node{"results"}
  if result.results.isNil:
    result.results = newJObject()

proc maxTick*(replay: Replay): int =
  if replay.frames.len == 0: 0 else: replay.frames[^1].t

proc rateAt*(replay: Replay, tick: int): int =
  ## The last printed rate at or before `tick`.
  result = 150
  for row in replay.rate:
    if row[0] > tick:
      break
    result = row[1]

proc cogAt*(frame: Frame, slot, field: int): int {.inline.} =
  frame.c[slot * 8 + field]

proc offerAt*(frame: Frame, slot, field: int): int {.inline.} =
  frame.o[slot * 4 + field]

proc replaySummaryLine*(replay: Replay): string =
  ## The endcard's tail line, built from the replay's own results block.
  let
    trades = replay.results{"total_trades"}.getInt()
    rate = replay.results{"mean_rate_x100"}.getInt()
  var starved = 0
  for item in replay.results{"starving_ticks"}:
    if item.getInt() > 0:
      inc starved
  $trades & " trades \u00b7 mean " & $(rate div 100) & "." &
    align($(rate mod 100), 2, '0') & " apples per banana \u00b7 " &
    $starved & (if starved == 1: " cog starved" else: " cogs starved")
