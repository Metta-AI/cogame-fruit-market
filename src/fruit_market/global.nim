## The sprite-protocol emitter and the one viewer state.
##
## Heavily reduced fork of coworld-ctf `src/ctf/global.nim`: the sprite
## emitter, the layer/object pooling, the chrome `TextMessage` smuggling and
## `boardRenderScaleFor` are kept. Fog-of-war/FOV, the first-person PiP, the
## articulated rigs, the grenade/spray/shield/barrier families, the endzone
## bakes, perks and handicaps are DELETED.
##
## The board is 1536 x 864 and always fits the frame, so there is no zoom, no
## minimap and no pan — the viewer drops `#viewpanel` entirely.

import
  std/[math, os, strutils, tables],
  pixie,
  bitworld/pixelfonts,
  bitworld/spriteprotocol

import ./sim_types, ./sim_config, ./sim_state, ./sim, ./replays, ./broadcast

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the chrome JSON.
    ## Smuggling the chrome through the SAME binary channel the board rides is
    ## what makes it survive every playback path.
  MapLayerId* = 0
  BandCount* = 8
  BandRows* = BoardH div BandCount
  MapBandSpriteBase* = 30
  MapBandObjectBase* = 40
  StaticBandZ* = -32768

  WaterSpriteBase = 100      ## 100 still, 101 rippled
  TreeSpriteBase = 110       ## apple ripe/bare, banana ripe/bare
  StallSpriteBase = 120
  CogSpriteBase = 200        ## 200 + slot * 4 + pose
  AliasSpriteBase = 240
  BarSpriteBase = 260
  BubbleSpriteBase = 280
  TagSpriteBase = 300
  LinkSpriteId = 330

  WaterObjectBase = 1000
  TreeObjectBase = 2000
  StallObjectBase = 2100
  CogObjectBase = 2200
  AliasObjectBase = 2240
  BarObjectBase = 2260
  BubbleObjectBase = 2280
  TagObjectBase = 2300
  LinkObjectBase = 2320

  WaterZ = -30000
  StallZ = -20000
  OverlayZ = 20000

  CogW = 36
  CogH = 48
  BarW = 40
  BarH = 8
  BubbleH = 26
  TagH = 12

const
  ReplayHalfSpeed* = 0
    ## `speed` sentinel for the replay-only 1/2x playback (command '5'):
    ## the playhead advances one frame every OTHER presentation frame
    ## (halfPhase parity).

type
  ViewerState* = object
    ## One viewer. The wasm bundle owns exactly one; the live `/global` server
    ## keeps one per socket.
    initialized*: bool
    index*: int              ## playhead: an index into `replay.frames`
    playing*: bool
    speed*: int
      ## Integer playback multiplier, or ReplayHalfSpeed (0) for 1/2x.
    halfPhase*: bool
      ## Frame parity while at 1/2x speed: the playhead advances only on the
      ## odd frames, toggled once per advanceReplay frame.
    looping*: bool
    seekTick*: int           ## queued seek, -1 = none
    pendingSeek*: int        ## a click that arrived before the first frame
    commands*: seq[char]
    leadSent*: bool
    spriteLabels*: Table[int, string]
    liveObjects*: Table[int, bool]
    frameCounter*: int
    bandsSent*: int

  BoardArt = object
    loaded: bool
    floors: array[3, Image]     ## orchard, market, island
    water: array[2, Image]
    wall: Image
    trees: array[4, Image]      ## apple ripe, apple bare, banana ripe, bare
    fruit: array[2, Image]      ## apple, banana (bubble size)
    fruitSmall: array[2, Image]
    stalls: array[StallId, Image]
    cogs: array[Seats, array[3, Image]]   ## front, wade, slump
    bubble: Image
    burst: Image
    font: PixelFont

var art: BoardArt

proc boardRenderScaleFor*(width, height: int): int =
  ## Board pixels per LOGICAL cell-grid pixel. Fruit Market renders one board
  ## pixel per board pixel — the whole thing fits the frame at every size.
  1

proc dataDir*(): string =
  ## The working directory first. `os.getAppDir` has no emscripten
  ## implementation and dies with "value out of range: -1" BEFORE any fallback
  ## runs, so the lookup is guarded (chemistry, 2026-08-25).
  if dirExists("data"):
    return "data"
  when not defined(emscripten):
    try:
      let appDir = getAppDir()
      for candidate in [appDir / "data", appDir / ".." / "data"]:
        if dirExists(candidate):
          return candidate
    except CatchableError:
      discard
  "data"

proc solid(w, h: int, color: ColorRGBA): Image =
  result = newImage(w, h)
  result.fill(color)

proc loadOr(path: string, w, h: int, color: ColorRGBA): Image =
  ## Real art when it is there, a flat plate when it is not, so a missing asset
  ## degrades to a drawable board instead of an aborted runtime.
  try:
    if fileExists(path):
      let image = readImage(path)
      if image.width == w and image.height == h:
        return image
      return image.resize(w, h)
  except CatchableError:
    discard
  solid(w, h, color)

proc scaleUp(image: Image, factor: int): Image =
  result = newImage(image.width * factor, image.height * factor)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result[x, y] = image[x div factor, y div factor]

proc textImage(text: string, scale: int, color: ColorRGBA,
    pad = 2): Image =
  ## A tight pixel-font label, scaled up so it reads at board size.
  let
    w = max(1, art.font.textWidth(text))
    h = max(1, art.font.height)
  var small = newImage(w, h)
  small.fill(rgba(0, 0, 0, 0))
  small.drawText(art.font, text, 0, 0, color)
  let big = small.scaleUp(scale)
  result = newImage(big.width + pad * 2, big.height + pad * 2)
  result.fill(rgba(0, 0, 0, 0))
  result.draw(big, translate(vec2(float32(pad), float32(pad))))

proc plateText(text: string, scale: int, fg, bg: ColorRGBA): Image =
  ## A label on a rounded dark plate, which is what keeps an alias legible over
  ## grass, water and a fruit tree alike.
  let label = textImage(text, scale, fg, pad = 0)
  result = newImage(label.width + 8, label.height + 6)
  result.fill(rgba(0, 0, 0, 0))
  let ctx = newContext(result)
  ctx.fillStyle = bg
  ctx.fillRoundedRect(rect(vec2(0, 0),
    vec2(float32(result.width), float32(result.height))), 4.0)
  result.draw(label, translate(vec2(4, 3)))

proc loadArt*() =
  if art.loaded:
    return
  art.loaded = true
  art.font = readTiny5Font()
  let dir = dataDir()
  art.floors[0] = loadOr(dir / "floor_orchard.png", CellPx, CellPx,
    rgba(96, 138, 74, 255))
  art.floors[1] = loadOr(dir / "floor_market.png", CellPx, CellPx,
    rgba(158, 137, 104, 255))
  art.floors[2] = loadOr(dir / "floor_island.png", CellPx, CellPx,
    rgba(112, 150, 88, 255))
  art.water[0] = loadOr(dir / "water_still.png", CellPx, CellPx,
    rgba(48, 104, 160, 255))
  art.water[1] = loadOr(dir / "water_ripple.png", CellPx, CellPx,
    rgba(58, 120, 178, 255))
  art.wall = loadOr(dir / "wall_stone.png", CellPx, CellPx,
    rgba(64, 58, 52, 255))
  art.trees[0] = loadOr(dir / "tree_apple_ripe.png", CellPx, CellPx,
    rgba(56, 108, 52, 255))
  art.trees[1] = loadOr(dir / "tree_apple_bare.png", CellPx, CellPx,
    rgba(92, 78, 58, 255))
  art.trees[2] = loadOr(dir / "tree_banana_ripe.png", CellPx, CellPx,
    rgba(70, 122, 58, 255))
  art.trees[3] = loadOr(dir / "tree_banana_bare.png", CellPx, CellPx,
    rgba(92, 82, 58, 255))
  art.fruit[0] = loadOr(dir / "fruit_apple.png", 22, 22, rgba(214, 62, 48, 255))
  art.fruit[1] = loadOr(dir / "fruit_banana.png", 22, 22,
    rgba(232, 200, 62, 255))
  art.fruitSmall[0] = art.fruit[0].resize(14, 14)
  art.fruitSmall[1] = art.fruit[1].resize(14, 14)
  for id in StallId:
    art.stalls[id] = loadOr(dir / ("stall_" & $id & ".png"), CellPx * 2,
      CellPx + 16, rgba(196, 84, 62, 255))
  for slot in 0 ..< Seats:
    let colour = CogColorNames[slot].replace(" ", "_")
    let rgb = CogColorRgb[slot]
    let tint = rgba(uint8(rgb[0]), uint8(rgb[1]), uint8(rgb[2]), 255)
    art.cogs[slot][0] = loadOr(dir / ("cog_" & colour & "_front.png"),
      CogW, CogH, tint)
    art.cogs[slot][1] = loadOr(dir / ("cog_" & colour & "_wade.png"),
      CogW, CogH, tint)
    art.cogs[slot][2] = loadOr(dir / ("cog_" & colour & "_slump.png"),
      CogW, CogH, tint)
  art.bubble = loadOr(dir / "offer_bubble.png", 96, BubbleH,
    rgba(24, 18, 12, 220))
  art.burst = loadOr(dir / "trade_burst.png", 48, 48, rgba(255, 236, 160, 200))

# --- the static bake ---------------------------------------------------------

proc bakeBand(board: ReplayBoard, band: int): Image =
  result = newImage(BoardW, BandRows)
  result.fill(rgba(20, 16, 12, 255))
  let y0 = band * BandRows
  for cy in 0 ..< Rows:
    let py = cy * CellPx - y0
    if py + CellPx <= 0 or py >= BandRows:
      continue
    for cx in 0 ..< Cols:
      let zone = board.zone[idx(cx, cy)]
      let tile =
        case zone
        of zWall: art.wall
        of zWater: art.floors[1]     ## the riverbed under the animated water
        of zOrchard: art.floors[0]
        of zMarket: art.floors[1]
        of zIsland: art.floors[2]
      result.draw(tile, translate(vec2(float32(cx * CellPx), float32(py))))

proc pixelsOf(image: Image): seq[uint8] =
  result = newSeq[uint8](image.width * image.height * 4)
  var i = 0
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let px = image[x, y]
      result[i] = px.r
      result[i + 1] = px.g
      result[i + 2] = px.b
      result[i + 3] = px.a
      i += 4

proc addSpriteOnce(state: var ViewerState, packet: var seq[uint8],
    spriteId: int, image: Image, label: string) =
  ## Content-keyed sprite definition: a sprite whose label has not changed is
  ## not re-sent, which is what keeps a per-frame bar or bubble cheap.
  if state.spriteLabels.getOrDefault(spriteId, "\u0000") == label:
    return
  state.spriteLabels[spriteId] = label
  packet.addSprite(spriteId, image.width, image.height, pixelsOf(image), label)

proc barImage(hunger, stamina: int): Image =
  ## Two segments under every cog: hunger on top (green -> amber -> red),
  ## stamina below (blue).
  result = newImage(BarW, BarH)
  result.fill(rgba(14, 11, 8, 210))
  let hw = clamp(hunger * (BarW - 2) div max(1, HungerMax), 0, BarW - 2)
  let sw = clamp(stamina * (BarW - 2) div max(1, StaminaMax), 0, BarW - 2)
  let hungerColor =
    if hunger > 60: rgba(88, 194, 106, 255)
    elif hunger > 25: rgba(226, 176, 62, 255)
    else: rgba(222, 76, 62, 255)
  for x in 0 ..< hw:
    for y in 1 .. 3:
      result[x + 1, y] = hungerColor
  for x in 0 ..< sw:
    for y in 4 .. 6:
      result[x + 1, y] = rgba(86, 148, 220, 255)

proc bubbleImage(giveFruit: int, giveN, wantN: int, unfunded: bool,
    pulsing: bool): Image =
  ## `3 (apple) -> 2 (banana)` in SPRITES and digits, tinted by the fruit it
  ## gives. An unfunded offer is drawn hollow with a dashed outline.
  let
    wantFruit = 1 - giveFruit
    giveDigits = textImage($giveN, 3, rgba(246, 240, 226, 255), pad = 0)
    wantDigits = textImage($wantN, 3, rgba(246, 240, 226, 255), pad = 0)
    arrow = textImage("->", 2, rgba(226, 208, 176, 255), pad = 0)
    w = 12 + giveDigits.width + 2 + 18 + 6 + arrow.width + 6 + wantDigits.width +
      2 + 18 + 12
  result = newImage(w, BubbleH)
  result.fill(rgba(0, 0, 0, 0))
  let ctx = newContext(result)
  let tint =
    if giveFruit == 0: rgba(150, 44, 36, 235) else: rgba(146, 118, 26, 235)
  ctx.fillStyle =
    if unfunded: rgba(20, 16, 12, 110) else: tint
  ctx.fillRoundedRect(rect(vec2(0, 0),
    vec2(float32(w), float32(BubbleH))), 8.0)
  ctx.strokeStyle =
    if pulsing: rgba(255, 240, 170, 255)
    elif unfunded: rgba(226, 208, 176, 170)
    else: rgba(16, 12, 8, 220)
  ctx.lineWidth = if pulsing: 3.0 else: 2.0
  ctx.strokeRoundedRect(rect(vec2(1, 1),
    vec2(float32(w - 2), float32(BubbleH - 2))), 8.0)
  var pen = 12
  result.draw(giveDigits, translate(vec2(float32(pen),
    float32((BubbleH - giveDigits.height) div 2))))
  pen += giveDigits.width + 2
  result.draw(art.fruitSmall[giveFruit], translate(vec2(float32(pen),
    float32((BubbleH - 14) div 2))))
  pen += 18 + 6
  result.draw(arrow, translate(vec2(float32(pen),
    float32((BubbleH - arrow.height) div 2))))
  pen += arrow.width + 6
  result.draw(wantDigits, translate(vec2(float32(pen),
    float32((BubbleH - wantDigits.height) div 2))))
  pen += wantDigits.width + 2
  result.draw(art.fruitSmall[wantFruit], translate(vec2(float32(pen),
    float32((BubbleH - 14) div 2))))

proc aliasImage(name: string, slot: int, farm: Fruit): Image =
  ## The alias under the feet with a fruit badge — the badge is what says which
  ## guild a cog belongs to without a label.
  let rgb = CogColorRgb[slot]
  let label = plateText(name.toUpperAscii(), 2, rgba(246, 240, 226, 255),
    rgba(18, 14, 10, 215))
  result = newImage(label.width + 18, max(label.height, 16))
  result.fill(rgba(0, 0, 0, 0))
  let badge = art.fruitSmall[fruitId(farm)]
  result.draw(badge, translate(vec2(0, float32((result.height - 14) div 2))))
  result.draw(label, translate(vec2(16,
    float32((result.height - label.height) div 2))))
  let ctx = newContext(result)
  ctx.strokeStyle = rgba(uint8(rgb[0]), uint8(rgb[1]), uint8(rgb[2]), 255)
  ctx.lineWidth = 2.0
  ctx.strokeRoundedRect(rect(vec2(16, float32((result.height -
    label.height) div 2)), vec2(float32(label.width), float32(label.height))),
    4.0)

proc tagImage(text: string, color: ColorRGBA): Image =
  plateText(text, 2, rgba(255, 240, 226, 255), color)

# --- the packet --------------------------------------------------------------

proc initViewerState*(): ViewerState =
  result.playing = true
  result.speed = 1
  result.seekTick = -1
  result.pendingSeek = -1
  result.spriteLabels = initTable[int, string]()
  result.liveObjects = initTable[int, bool]()

proc applyViewerMessage*(state: var ViewerState, message: string) =
  ## Transport commands ride the sprite protocol's chat channel, exactly as
  ## paintbot's do. A multi-digit tick is intercepted before the char-by-char
  ## path so it is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.seekTick = tick
      elif item.text.startsWith("v:"):
        discard      ## no POV lens: there is no fog to look through
      else:
        for ch in item.text:
          state.commands.add(ch)
    else:
      discard

proc emitBands(state: var ViewerState, packet: var seq[uint8],
    board: ReplayBoard) =
  ## The static terrain bake is ~5 MB of RGBA. Snappy takes it to ~800 kB,
  ## which is over the hosted replay's 1 MiB websocket frame limit once the
  ## rest of a frame rides with it, so the bands are DRIPPED: a couple per
  ## presentation frame until the board is complete (paintbot bands the map
  ## for exactly this reason). The client caches each band forever.
  const BandsPerFrame = 2
  var emitted = 0
  while state.bandsSent < BandCount and emitted < BandsPerFrame:
    let band = state.bandsSent
    let image = bakeBand(board, band)
    state.addSpriteOnce(packet, MapBandSpriteBase + band, image,
      "band" & $band)
    packet.addObject(MapBandObjectBase + band, 0, band * BandRows,
      StaticBandZ, MapLayerId, MapBandSpriteBase + band)
    state.bandsSent.inc
    emitted.inc

proc emitStatic(state: var ViewerState, packet: var seq[uint8],
    board: ReplayBoard) =
  if state.initialized:
    return
  state.initialized = true
  loadArt()
  packet.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
  packet.addViewport(MapLayerId, BoardW, BoardH)
  for i in 0 .. 1:
    state.addSpriteOnce(packet, WaterSpriteBase + i, art.water[i], "water" & $i)
  for i in 0 .. 3:
    state.addSpriteOnce(packet, TreeSpriteBase + i, art.trees[i], "tree" & $i)
  for id in StallId:
    var image = newImage(art.stalls[id].width, art.stalls[id].height + 14)
    image.fill(rgba(0, 0, 0, 0))
    image.draw(art.stalls[id], translate(vec2(0, 0)))
    let label = plateText(($id).toUpperAscii(), 2, rgba(255, 246, 226, 255),
      rgba(24, 16, 10, 220))
    image.draw(label, translate(vec2(
      float32((image.width - label.width) div 2),
      float32(art.stalls[id].height))))
    state.addSpriteOnce(packet, StallSpriteBase + ord(id), image, "stall" & $id)
  for slot in 0 ..< Seats:
    state.addSpriteOnce(packet, CogSpriteBase + slot * 4 + 0,
      art.cogs[slot][0], "cog" & $slot & "f")
    state.addSpriteOnce(packet, CogSpriteBase + slot * 4 + 1,
      art.cogs[slot][1], "cog" & $slot & "w")
    state.addSpriteOnce(packet, CogSpriteBase + slot * 4 + 2,
      art.cogs[slot][2], "cog" & $slot & "s")
  var link = newImage(8, 8)
  link.fill(rgba(255, 236, 160, 200))
  state.addSpriteOnce(packet, LinkSpriteId, link, "link")

proc keepObject(state: var ViewerState, packet: var seq[uint8], objectId: int,
    x, y, z, spriteId: int) =
  packet.addObject(objectId, x, y, z, MapLayerId, spriteId)
  state.liveObjects[objectId] = true

proc overlayX(cellX, spriteW: int): int =
  ## An overlay is CENTRED over its cog's cell and then kept inside the board.
  ## A canvas accepts a draw at a negative coordinate without complaint, so a
  ## bubble over a cog in column 1 would simply be invisible from its left edge
  ## in (cogchemists, 2026-08-24). tests/test_global.nim asserts the result.
  clamp(cellX * CellPx + (CellPx - spriteW) div 2, 0, max(0, BoardW - spriteW))

proc overlayY(top, spriteH: int): int =
  clamp(top, 0, max(0, BoardH - spriteH))

proc buildPacket*(state: var ViewerState, board: ReplayBoard,
    view: ChromeView, treeBare: openArray[int], chrome: string): seq[uint8] =
  ## One presentation frame: the board objects, then the chrome JSON smuggled
  ## in the label of the reserved 1x1 sprite.
  state.emitStatic(result, board)
  state.emitBands(result, board)
  var wanted = initTable[int, bool]()

  ## Animated water. The still and rippled tiles alternate on a per-cell phase
  ## so the two rivers shimmer rather than blink in lockstep.
  let phase = (view.tick div 6)
  for i in 0 ..< Cols * Rows:
    if board.zone[i] != zWater:
      continue
    let
      cx = i mod Cols
      cy = i div Cols
      variant = (phase + cx + cy) mod 2
    state.keepObject(result, WaterObjectBase + i, cx * CellPx, cy * CellPx,
      WaterZ, WaterSpriteBase + variant)
    wanted[WaterObjectBase + i] = true

  for id in StallId:
    let stall = board.stalls[id]
    let objectId = StallObjectBase + ord(id)
    state.keepObject(result, objectId,
      stall.x * CellPx - CellPx div 2, stall.y * CellPx - 14, StallZ,
      StallSpriteBase + ord(id))
    wanted[objectId] = true

  for i, tree in board.trees:
    let bare = if i < treeBare.len: treeBare[i] else: 0
    let sprite = TreeSpriteBase +
      (if tree.fruit == fApple: 0 else: 2) + (if bare > 0: 1 else: 0)
    let objectId = TreeObjectBase + i
    state.keepObject(result, objectId, tree.x * CellPx, tree.y * CellPx,
      0, sprite)
    wanted[objectId] = true

  for slot in 0 ..< Seats:
    let cog = view.cogs[slot]
    let
      px = cog.x * CellPx + (CellPx - CogW) div 2
      py = cog.y * CellPx + (CellPx - CogH) + 4
      pose =
        if (cog.flags and FlagExhausted) != 0: 2
        elif (cog.flags and FlagWading) != 0: 1
        else: 0
    state.keepObject(result, CogObjectBase + slot, px, py, 0,
      CogSpriteBase + slot * 4 + pose)
    wanted[CogObjectBase + slot] = true

    let bar = barImage(cog.hunger, cog.stamina)
    state.addSpriteOnce(result, BarSpriteBase + slot, bar,
      "bar" & $cog.hunger & "-" & $cog.stamina)
    state.keepObject(result, BarObjectBase + slot,
      overlayX(cog.x, BarW), overlayY(py - 10, BarH), OverlayZ,
      BarSpriteBase + slot)
    wanted[BarObjectBase + slot] = true

    let alias = aliasImage(view.names[slot], slot, view.farmTypes[slot])
    state.addSpriteOnce(result, AliasSpriteBase + slot, alias,
      "alias" & view.names[slot] & $view.farmTypes[slot])
    state.keepObject(result, AliasObjectBase + slot,
      overlayX(cog.x, alias.width),
      overlayY(cog.y * CellPx + CellPx + 2, alias.height), OverlayZ,
      AliasSpriteBase + slot)
    wanted[AliasObjectBase + slot] = true

    if cog.offerGive >= 0:
      var pulsing = false
      for otherSlot in 0 ..< Seats:
        if otherSlot == slot:
          continue
        let their = view.cogs[otherSlot]
        if their.offerGive < 0 or their.offerGive == cog.offerGive:
          continue
        if their.offerGiveN == cog.offerWantN and
            their.offerWantN == cog.offerGiveN and
            chebyshev(cog.x, cog.y, their.x, their.y) <= TradeRadius:
          pulsing = true
      let bubble = bubbleImage(cog.offerGive, cog.offerGiveN, cog.offerWantN,
        cog.offerUnfunded, pulsing)
      state.addSpriteOnce(result, BubbleSpriteBase + slot, bubble,
        "bub" & $cog.offerGive & "-" & $cog.offerGiveN & "-" &
        $cog.offerWantN & "-" & $cog.offerUnfunded & "-" & $pulsing)
      state.keepObject(result, BubbleObjectBase + slot,
        overlayX(cog.x, bubble.width),
        overlayY(py - 10 - BubbleH - 4, bubble.height), OverlayZ,
        BubbleSpriteBase + slot)
      wanted[BubbleObjectBase + slot] = true

    if (cog.flags and FlagStarving) != 0 or (cog.flags and FlagExhausted) != 0:
      let text =
        if (cog.flags and FlagExhausted) != 0: "EXHAUSTED" else: "STARVING"
      let tag = tagImage(text,
        if (cog.flags and FlagExhausted) != 0: rgba(70, 70, 78, 230)
        else: rgba(190, 54, 44, 235))
      state.addSpriteOnce(result, TagSpriteBase + slot, tag, "tag" & text)
      state.keepObject(result, TagObjectBase + slot,
        overlayX(cog.x, tag.width),
        overlayY(py - 10 - TagH - BubbleH - 8, tag.height), OverlayZ,
        TagSpriteBase + slot)
      wanted[TagObjectBase + slot] = true

  ## Retire anything that is no longer on the board, so a withdrawn offer's
  ## bubble does not linger.
  var stale: seq[int]
  for objectId in state.liveObjects.keys:
    if not wanted.hasKey(objectId):
      stale.add(objectId)
  for objectId in stale:
    result.addDeleteObject(objectId)
    state.liveObjects.del(objectId)

  result.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)
  state.frameCounter.inc

proc displaySpeed*(state: ViewerState): float =
  ## The speed the chrome shows: 0.5 at the half-speed sentinel, else the
  ## integer multiplier.
  if state.speed == ReplayHalfSpeed: 0.5
  else: float(state.speed)

proc steppedSpeed(current, step: int): int =
  ## The `+` / `-` transport keys walk the SAME speed ladder the number keys
  ## select from (paintbot's `applySpeedCommand`). The page sends them; without
  ## this they fell through to `else: discard` and did nothing. The ladder now
  ## reaches one rung below 1x: '-' from 1x lands on the 1/2x sentinel, the
  ## floor, and '+' climbs back out onto 1x.
  if current == ReplayHalfSpeed:
    return (if step > 0: PlaybackSpeeds[0] else: ReplayHalfSpeed)
  var index = 0
  for i, value in PlaybackSpeeds:
    if value == current:
      index = i
  if index + step < 0:
    return ReplayHalfSpeed
  PlaybackSpeeds[clamp(index + step, 0, PlaybackSpeeds.high)]

proc advanceReplay*(state: var ViewerState, replay: Replay) =
  ## Applies the queued transport commands and advances the playhead one
  ## presentation frame. A seek that arrives before the first chrome frame is
  ## QUEUED and converged with a bounded per-frame walk, never dropped.
  state.halfPhase = not state.halfPhase
  let last = replay.frames.high
  for command in state.commands:
    case command
    of ' ': state.playing = not state.playing
    of '.': state.index = min(last, state.index + TargetFps * 5)
    of 'b': state.index = max(0, state.index - 1)
    of ',': state.index = 0
    of 'e': state.index = last
    of 'r': state.looping = not state.looping
    of 'f': discard      ## skip-lulls: this game ships no lull spans
    of '+', '=': state.speed = steppedSpeed(state.speed, 1)
    of '-', '_': state.speed = steppedSpeed(state.speed, -1)
    of '5': state.speed = ReplayHalfSpeed
    of '1': state.speed = 1
    of '2': state.speed = 2
    of '3': state.speed = 3
    of '4': state.speed = 4
    of '8': state.speed = 8
    of '6': state.speed = 16
    else: discard
  state.commands.setLen(0)
  if state.seekTick >= 0:
    state.pendingSeek = state.seekTick
    state.seekTick = -1
  if state.pendingSeek >= 0:
    let target = clamp(state.pendingSeek, 0, last)
    let delta = target - state.index
    if abs(delta) <= SeekTicksPerFrame:
      state.index = target
      state.pendingSeek = -1
    else:
      state.index += (if delta > 0: SeekTicksPerFrame else: -SeekTicksPerFrame)
    return
  if not state.playing:
    return
  if state.speed == ReplayHalfSpeed:
    ## 1/2x: the playhead advances only every other presentation frame.
    if not state.halfPhase:
      return
    state.index += 1
  else:
    state.index += max(1, state.speed)
  if state.index > last:
    if state.looping:
      state.index = 0
    else:
      state.index = last
      state.playing = false
