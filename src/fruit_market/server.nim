## The Fruit Market game server: the Coworld game contract.
##
## Fork of coworld-ctf `src/ctf/server.nim`'s route/artifact/shutdown skeleton
## with bullwhip's JSON player frames. Hosted certification probes exactly
## these routes BEFORE the player pods start (lantern, 2026-08-23), so all four
## are registered ahead of any catch-all and neither `/client/` page opens the
## player socket.

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  bitworld/spriteprotocol,
  curly,
  mummy,
  mummy/routers

import
  ./sim_types, ./sim_config, ./board, ./events, ./sim_state, ./sim,
  ./scripted, ./llm, ./replays, ./broadcast, ./global, ./wire_constants

const
  MaxPromptLen = 4000
  PlayBudgetFraction = 0.6
    ## Share of the platform's episode timeout spent playing. The rest covers
    ## container start, player connects and writing the artifacts.

  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  BroadcastPage = staticRead("../../client/replay_broadcast.html")
  PlayerPage = staticRead("../../client/player.html")

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: array[Seats, string]
    scripted: array[Seats, ScriptKind]
    registered: array[Seats, bool]
    connected: array[Seats, bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewers: Table[WebSocket, ViewerState]
    eventsSent: int          ## sim.events already broadcast to spectators
    started: bool
    finished: bool
    shuttingDown: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server

initLock(stateLock)

proc servedGlobalPage(): string =
  ## The live spectator page: the same inherited chrome the static bundle
  ## serves, with the three markers spliced inline.
  result = BroadcastPage
    .replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
    .replace(ChromeCommonMarker, "<script>" & ChromeCommonJs & "</script>")
    .replace(BroadcastCoreMarker, "<script>" & BroadcastCoreJs & "</script>")

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc broadcastLocked(gs: var GameState) =
  ## Callers hold stateLock. Spectators get the board packet plus the chrome
  ## frame; players get their own redacted observation.
  if gs.sim.frames.len == 0:
    return
  var board: ReplayBoard
  board.cols = Cols
  board.rows = Rows
  board.cell = CellPx
  for i in 0 ..< Cols * Rows:
    board.zone[i] = gs.sim.board.zone[i]
    board.treeAt[i] = gs.sim.board.treeAt[i]
    board.stallAt[i] = gs.sim.board.stallAt[i]
  board.trees = gs.sim.board.trees
  board.stalls = gs.sim.board.stalls
  var bare: seq[int]
  for tree in gs.sim.board.trees:
    bare.add(tree.bareFor)
  var sockets: seq[WebSocket]
  for socket in gs.globalSockets:
    sockets.add(socket)
  ## The events emitted since the last broadcast, so the live feed draws the
  ## same rows the static replay does. Without them `events` was always empty
  ## and the game block's feed never ran on a live spectator.
  var events = newJArray()
  if gs.sim.events.len > gs.eventsSent:
    events = eventsJson(gs.sim.events[gs.eventsSent ..< gs.sim.events.len])
  gs.eventsSent = gs.sim.events.len
  for socket in sockets:
    var viewer = gs.viewers.getOrDefault(socket, initViewerState())
    let sendLead = not viewer.leadSent
    let view = chromeViewOfSim(gs.sim, events, sendLead)
    if sendLead:
      viewer.leadSent = true
    let packet = viewer.buildPacket(board, view, bare, buildStateJson(view))
    gs.viewers[socket] = viewer
    socket.send(blobFromBytes(packet), BinaryMessage)

proc sendPlayerStates(gs: GameState) =
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.observationJson(slot))

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var
    results: JsonNode
    replayData: string
    grace = 20
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    results = state.sim.resultsJson()
    replayData = $replayJson(state.sim, results)
    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists.
    var aliases = newJArray()
    for slot in 0 ..< Seats:
      aliases.add(%state.sim.aliases[slot])
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": aliases,
      "rounds": results["rounds"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "fruit-market: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  ## Hosted certification pings the global websocket AFTER the player pods
  ## start, so /healthz and /global keep answering for a bounded grace before
  ## the process exits (lantern, 2026-08-23).
  echo "fruit-market: artifacts written; holding /healthz and /global for ",
    grace, "s"
  withLock stateLock:
    state.shuttingDown = true
  sleep(grace * 1000)
  echo "fruit-market: episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float

    ## Adaptive lobby: return as soon as every connected socket has registered
    ## (commons-family, 2026-08-24) rather than burning the whole grace.
    while epochTime() < connectDeadline:
      var ready = false
      withLock stateLock:
        var connectedCount = 0
        var registeredCount = 0
        for slot in 0 ..< Seats:
          if state.connected[slot]:
            connectedCount.inc
            if state.registered[slot]:
              registeredCount.inc
        ready = connectedCount >= config.numAgents and
          registeredCount >= connectedCount
      if ready:
        break
      sleep(200)

    var anyConnected = false
    withLock stateLock:
      state.started = true
      for slot in 0 ..< Seats:
        if state.connected[slot]:
          anyConnected = true
      echo "fruit-market: starting with ", state.playerSockets.len, "/",
        config.numAgents, " players connected"

    if not anyConnected:
      ## No seat connected within playerConnectTimeoutSeconds: forfeit. All
      ## scores zero, results + replay are still written.
      withLock stateLock:
        state.sim.forfeit()
      finishEpisode(runtimeConfig)
      return

    let client = newLlmClient(config)

    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline = gameStart + timeoutSeconds * PlayBudgetFraction
    echo "fruit-market: episode timeout ", timeoutSeconds.int, "s (",
      (if hostedTimeout.len > 0: "from env" else: "assumed"),
      "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    var lastBatchStart = 0.0
    while true:
      var
        simCopy: Sim
        prompts: array[Seats, string]
        scripts: array[Seats, ScriptKind]
        connected: array[Seats, bool]
      withLock stateLock:
        if state.sim.done:
          break
        if epochTime() > playDeadline:
          echo "fruit-market: play deadline reached after ",
            state.sim.roundsPlayed, "/", config.rounds, " rounds; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        simCopy = state.sim
        prompts = state.prompts
        scripts = state.scripted
        connected = state.connected

      ## `minTurnSeconds` floors the spacing between BATCH STARTS, so the
      ## episode issues at most 8 requests / minTurnSeconds — under the Bedrock
      ## sidecar's 30 rpm per-episode ceiling that bit cogame-raid.
      if lastBatchStart > 0.0 and config.minTurnSeconds > 0:
        let wait = config.minTurnSeconds.float - (epochTime() - lastBatchStart)
        if wait > 0.0:
          sleep(int(wait * 1000.0))
      lastBatchStart = epochTime()

      ## The slow part (one parallel batch of eight) runs OUTSIDE the lock on a
      ## snapshot; only this thread mutates the sim, so it cannot go stale.
      let orders = client.decideAll(simCopy, prompts, scripts, connected)

      withLock stateLock:
        state.sim.setRoundOrders(orders)
        state.sim.runRound()
        echo "fruit-market: round ", state.sim.roundsPlayed, " of ",
          config.rounds, " done at ", (epochTime() - gameStart).int, "s"
        state.broadcastLocked()
        state.sendPlayerStates()

    withLock stateLock:
      if not state.sim.done:
        state.sim.finish("complete", "round_limit")
      state.broadcastLocked()
      state.sendPlayerStates()
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, body)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondHtml(request, servedGlobalPage())

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    ## View-only. It NEVER opens the player socket — the certifier probes this
    ## route before the player pods start and a page that grabbed the seat
    ## would fail the episode.
    respondHtml(request, PlayerPage)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        slot < Seats and state.config.tokens[slot] == token
    if not authorized:
      ## A bad token is refused with a close, never a hang.
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      state.connected[slot] = true
      echo "fruit-market: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.numAgents, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "fruit-market.player.v1",
        "slot": slot,
        "name": state.sim.aliases[slot],
        "rounds": state.config.rounds,
        "ticksPerRound": state.config.ticksPerRound,
        "variant": state.config.variantId()
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewers[websocket] = initViewerState()
      state.broadcastLocked()

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in state.viewers:
            var viewer = state.viewers[websocket]
            viewer.applyViewerMessage(message.data)
            state.viewers[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          echo "fruit-market: ignoring player frame of type ",
            payload{"type"}.getStr()
          return
        var prompt = payload{"prompt"}.getStr()
        if prompt.runeLen > MaxPromptLen:
          prompt = prompt.runeSubStr(0, MaxPromptLen)
        let node = payload{"scripted"}
        let kind =
          if node.isNil: skNone
          elif node.kind == JBool: (if node.getBool(): skHauler else: skNone)
          else: parseScriptKind(node.getStr())
        var firstTime = false
        withLock stateLock:
          firstTime = not state.registered[slot]
          state.prompts[slot] = prompt
          state.scripted[slot] = kind
          state.registered[slot] = true
        if firstTime:
          echo "fruit-market: slot ", slot, " registered (", prompt.len,
            " chars", (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "fruit-market: ignoring bad player frame: ",
          cleanText(error.msg, MaxErrorLen)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
            ## A seat whose socket DIES MID-EPISODE plays `hauler` for every
            ## remaining round: decideAll gates on `connected`, so leaving it
            ## set kept spending the operator's credentials on a prompt whose
            ## process is gone.
            state.connected[slot] = false
            echo "fruit-market: player slot ", slot,
              " disconnected; playing hauler for the rest of the episode"
        state.globalSockets.excl(websocket)
        state.viewers.del(websocket)

proc buildRouter(): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  var policyNames: seq[string]
  for player in config.players:
    policyNames.add(player.name)
  state.config = config
  state.sim = initSim(config, policyNames)
  for slot in 0 ..< Seats:
    state.scripted[slot] = skNone
  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "fruit-market: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
