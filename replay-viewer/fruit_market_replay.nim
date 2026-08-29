import
  std/json,
  fruit_market/[broadcast, global, replays, sim]

## The wasm replay entry. Same structure as coworld-ctf's
## `replay-viewer/ctf_replay.nim`: `stampStage`, `fm_load_replay`, `fm_frame`,
## `fm_input`, `fm_packet_ptr/_len`, `fm_error_ptr/_len`, `fm_stage_ptr/_len`,
## and the `emscripten_exit_with_live_runtime()` epilogue — without which Nim's
## `main` destroys every global while JS keeps calling in.
##
## `ctf_mismatch_tick` is DROPPED: Fruit Market records state, not inputs, so
## there is no re-simulation to mismatch.

var
  runtimeLoaded = false
  replay: Replay
  viewer: ViewerState
  packet: seq[uint8]
  lastError: string
  leadSent = false
  lastEvents: JsonNode

var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc eventsBetween(fromTick, toTick: int): JsonNode =
  ## Every recorded event in (fromTick, toTick]. The chrome applies them in
  ## order, so a 16x frame still tells the same story a 1x frame does.
  result = newJArray()
  if replay.events.isNil:
    return
  for row in replay.events:
    let t = row{"t"}.getInt()
    if t > fromTick and t <= toTick:
      result.add(row)

proc renderCurrent(events: JsonNode) =
  ## `fm_load_replay` builds the ONLY packet that carries `meta`; read it
  ## directly and never re-derive it from a later frame (matrix-games,
  ## 2026-08-24).
  let sendLead = not leadSent
  let view = chromeViewOfReplay(replay, viewer.index, viewer.playing,
    viewer.displaySpeed(), viewer.looping, sendLead, events)
  if sendLead:
    leadSent = true
  let frame = replay.frames[clamp(viewer.index, 0, replay.frames.high)]
  packet = viewer.buildPacket(replay.board, view, frame.r, buildStateJson(view))

proc fmLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "fm_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    replay = parseReplay(data.bytesFromPointer(int(length)))
    stampStage("initialize viewer")
    viewer = initViewerState()
    leadSent = false
    lastEvents = newJArray()
    runtimeLoaded = true
    frameStage = "advance replay (" & $replay.frames.len & " frames)"
    stampStage("render first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    return 0

proc fmInput(data: ptr uint8, length: cint) {.exportc: "fm_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyViewerMessage(data.bytesFromPointer(int(length)))

proc fmFrame(): cint {.exportc: "fm_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let before = replay.frames[clamp(viewer.index, 0, replay.frames.high)].t
    viewer.advanceReplay(replay)
    let after = replay.frames[clamp(viewer.index, 0, replay.frames.high)].t
    let events =
      if after > before: eventsBetween(before, after)
      elif after == before and before == 0: eventsBetween(-1, 0)
      else: newJArray()
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg
    return -1

proc fmPacketPointer(): ptr uint8 {.exportc: "fm_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc fmPacketLength(): cint {.exportc: "fm_packet_len", cdecl.} =
  cint(packet.len)

proc fmErrorPointer(): ptr uint8 {.exportc: "fm_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc fmErrorLength(): cint {.exportc: "fm_error_len", cdecl.} =
  cint(lastError.len)

proc fmStagePointer(): ptr uint8 {.exportc: "fm_stage_ptr", cdecl.} =
  ## The progress note. Unlike fm_error_*, this stays valid after an
  ## allocation-failure abort, so JS can still report what the runtime was
  ## doing when the address space ran out.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc fmStageLength(): cint {.exportc: "fm_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  emscriptenExitWithLiveRuntime()
