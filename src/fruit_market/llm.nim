## Claude-backed decision making for Fruit Market.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. A policy is a prompt:
## the GAME composes each seat's observation plus that seat's `PLAYER_PROMPT`
## and asks Claude for one standing order per round.
##
## Decisions within a round are SIMULTANEOUS by rule, so all eight seats'
## requests go out as ONE parallel batch (`curly.makeRequests`) — never
## sequentially and never one seat at a time. An invalid reply is retried once,
## in the same round's retry batch, with a hint; anything still failing falls
## back to the `hauler` order and is recorded `"source":"fallback"`.
##
## Credentials, in order: Bedrock sidecar -> ANTHROPIC_API_KEY ->
## ANTHROPIC_API_KEY_URI. With none the client disables itself immediately and
## every seat plays `hauler`, which is what keeps offline certification green
## and deterministic.

import
  std/[json, os, strutils, times],
  bitworld/runtime,
  curly,
  ./sim_types, ./sim_config, ./board, ./sim_state, ./sim, ./scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  TapeRows = 8
  RetryHint = "\nYour previous reply was invalid. Respond with ONLY the " &
    "requested JSON object, using one of the listed job, fruit, stall and " &
    "eat values, and offer quantities between 1 and 6."

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool

proc bedrockModelIds(): seq[string] =
  ## HAIKU ONLY (raid 2026-08-23, reconfirmed paintball 2026-08-25): the sonnet
  ## fallback times out on every sidecar call and turns one throttle into a
  ## cascade. BEDROCK_MODEL pins a single id.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "fruit-market llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: max(1000, config.maxOutputTokens),
    timeoutSeconds: max(1, config.llmTimeoutSeconds)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "fruit-market llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "fruit-market llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "fruit-market llm: no LLM credentials; every seat plays hauler"

# ---- the observation --------------------------------------------------------

proc zoneName(sim: Sim, x, y: int): string = $sim.board.zoneAt(x, y)

proc viewMap*(sim: Sim, slot: int): seq[string] =
  ## The 13 x 13 local ASCII map centred on the seat.
  let
    cog = sim.cogs[slot]
    r = sim.config.viewRadius
  for dy in -r .. r:
    var row = ""
    for dx in -r .. r:
      let
        x = cog.x + dx
        y = cog.y + dy
      if not onBoard(x, y):
        row.add('#')
        continue
      var ch = '.'
      case sim.board.zoneAt(x, y)
      of zWall: ch = '#'
      of zWater: ch = '~'
      else: ch = '.'
      let at = sim.board.treeAt[idx(x, y)]
      if at >= 0:
        let tree = sim.board.trees[at]
        ch =
          if tree.fruit == fApple: (if tree.bareFor == 0: 'A' else: 'a')
          else: (if tree.bareFor == 0: 'B' else: 'b')
      elif sim.board.stallAt[idx(x, y)] >= 0:
        ch = 'S'
      for otherSlot in 0 ..< Seats:
        if sim.cogs[otherSlot].x == x and sim.cogs[otherSlot].y == y:
          ch = char(ord('0') + otherSlot)
      row.add(ch)
    result.add(row)

proc offerJson(offer: Offer): JsonNode =
  if not offer.active:
    return newJNull()
  %*{
    "give": {"fruit": $offer.giveFruit, "n": offer.giveN},
    "want": {"fruit": $offer.wantFruit, "n": offer.wantN},
    "unfunded": offer.unfunded,
    "postedRound": offer.postedRound
  }

proc observationJson*(sim: Sim, slot: int): JsonNode =
  ## The `state` frame, sent at every round boundary and at episode end, and
  ## rendered into the user prompt. Static geography is public, dynamic state
  ## is local (radius 6), executed prices are global.
  let
    cog = sim.cogs[slot]
    field = dijkstra(sim.board, cog.x, cog.y)
    r = sim.config.viewRadius
  var cogs = newJArray()
  for otherSlot in 0 ..< Seats:
    if otherSlot == slot:
      continue
    let their = sim.cogs[otherSlot]
    let dist = chebyshev(cog.x, cog.y, their.x, their.y)
    if dist > r:
      continue
    var entry = %*{
      "alias": sim.aliases[otherSlot],
      "slot": otherSlot,
      "cell": [their.x, their.y],
      "dist": dist,
      "mirrorsYou": mirrors(cog.offer, their.offer)
    }
    entry["offer"] =
      if their.offer.active:
        %*{
          "give": {"fruit": $their.offer.giveFruit, "n": their.offer.giveN},
          "want": {"fruit": $their.offer.wantFruit, "n": their.offer.wantN},
          "unfunded": their.offer.unfunded
        }
      else:
        newJNull()
    cogs.add(entry)
  var ripe = newJArray()
  for tree in sim.board.trees:
    if tree.bareFor != 0:
      continue
    let dist = chebyshev(cog.x, cog.y, tree.x, tree.y)
    if dist > r:
      continue
    ripe.add(%*{"fruit": $tree.fruit, "cell": [tree.x, tree.y], "dist": dist})
  var stalls = newJArray()
  for id in StallId:
    stalls.add(%*{
      "name": $id,
      "cell": [sim.board.stalls[id].x, sim.board.stalls[id].y],
      "dist": sim.stallDistance(field, id)})
  var tape = newJArray()
  let first = max(0, sim.tape.len - TapeRows)
  for i in first ..< sim.tape.len:
    let row = sim.tape[i]
    tape.add(%*{
      "t": row.t,
      "give": $row.giveFruit, "giveN": row.giveN,
      "want": $row.wantFruit, "wantN": row.wantN,
      "applesPerBanana": row.applesPerBanana,
      "a": sim.aliases[row.a], "b": sim.aliases[row.b]})
  var history = newJArray()
  for row in sim.history[slot]:
    history.add(%*{
      "round": row.round, "score": row.score, "hunger": row.hunger,
      "stamina": row.stamina, "trades": row.trades,
      "harvested": row.harvested, "eaten": row.eaten,
      "crossings": row.crossings, "marketRate": row.marketRate})
  var mapRows = newJArray()
  for row in sim.viewMap(slot):
    mapRows.add(%row)
  var lastOrder = newJNull()
  if cog.hasOrder:
    lastOrder = %*{
      "job": $cog.order.job,
      "stall": (if cog.order.hasStall: $cog.order.stall else: ""),
      "eat": $cog.order.eat,
      "source": $cog.order.source}
  %*{
    "type": "state",
    "protocol": "fruit-market.player.v1",
    "slot": slot,
    "name": sim.aliases[slot],
    "round": sim.roundOf(),
    "rounds": sim.config.rounds,
    "ticksPerRound": sim.config.ticksPerRound,
    "tick": sim.tick,
    "board": {
      "cols": Cols, "rows": Rows, "variant": sim.config.variantId()},
    "you": {
      "cell": [cog.x, cog.y],
      "zone": sim.zoneName(cog.x, cog.y),
      "farmType": $cog.farm,
      "craves": $cog.craved(),
      "apples": cog.apples,
      "bananas": cog.bananas,
      "hunger": cog.hunger,
      "stamina": cog.stamina,
      "score": cog.score,
      "exhausted": cog.exhausted,
      "tradesThisEpisode": cog.trades,
      "offer": offerJson(cog.offer),
      "lastOrder": lastOrder
    },
    "view": {
      "radius": r,
      "map": mapRows,
      "legend": {
        ".": "land", "~": "water", "#": "wall",
        "A": "apple tree (ripe)", "a": "apple tree (bare)",
        "B": "banana tree (ripe)", "b": "banana tree (bare)",
        "S": "stall", "0-7": "a cog, by slot"},
      "cogs": cogs,
      "ripeTrees": ripe
    },
    "stalls": stalls,
    "tape": tape,
    "history": history,
    "notes": cog.notes,
    "rules": {
      "scoring": "5 points per craved fruit you eat, 1 per own fruit; " &
        "higher is better",
      "yourFruit": $cog.farm,
      "cravedFruit": $cog.craved(),
      "harvest": $sim.config.yieldOwn & " of your own fruit per harvest " &
        "every " & $sim.config.harvestCooldownOwn & " ticks in your grove; " &
        $sim.config.yieldOther & " per harvest every " &
        $sim.config.harvestCooldownOther & " ticks in the far grove",
      "trade": "an offer clears only against its EXACT mirror (their give " &
        "== your want, same numbers) within " & $sim.config.tradeRadius &
        " cells, once per round per cog",
      "water": "entering a river cell costs " & $sim.config.moveStaminaWater &
        " stamina and " & $sim.config.waterMoveCooldown & " ticks",
      "hunger": "-1 every " & $sim.config.hungerDrainPeriod & " ticks; at 0 " &
        "you lose " & $sim.config.starveDrain & " stamina per tick and " &
        "cannot move or harvest at 0 stamina",
      "eat": "one fruit per " & $sim.config.eatCooldown & " ticks; the fruit " &
        "you crave gives +" & $sim.config.craveNutrition & " hunger, your " &
        "own +" & $sim.config.ownNutrition,
      "geography": "your grove is the outer ring, bananas grow on the inner " &
        "island, the market ring with the four stalls is one river from each",
      "caps": {
        "inventory": sim.config.invCap,
        "offerN": [OfferMin, sim.config.offerMax],
        "tradeRadius": sim.config.tradeRadius,
        "viewRadius": sim.config.viewRadius}
    }
  }

# ---- prompts ----------------------------------------------------------------

proc systemPrompt*(sim: Sim, slot: int): string =
  let
    cog = sim.cogs[slot]
    me = sim.aliases[slot].toUpperAscii()
    mine = $cog.farm
    craved = $cog.craved()
  result.add("You are " & me & ", a " & mine & " farmer in Fruit Market.\n\n")
  result.add("""THE BOARD (fixed, identical every episode): a 32 x 18 walled
grid of four concentric belts. The OUTER RING is the apple grove (24 apple
trees). Inside it runs the OUTER RIVER, one cell wide. Inside that is the
MARKET RING, which grows nothing and holds four named stalls: NORTH, EAST,
SOUTH and WEST. Inside that runs the INNER RIVER. At the centre is the ISLAND,
the banana grove (24 banana trees). Each grove is ONE river from the market
ring and TWO rivers from the other grove.

""")
  result.add("You grow " & mine & "s. You score five times as much for eating " &
    craved & "s. The only cheap way to get them is a TRADE.\n\n")
  result.add("CONSTANTS: inventory cap " & $sim.config.invCap &
    " per fruit; harvest " & $sim.config.yieldOwn & " of your own fruit every " &
    $sim.config.harvestCooldownOwn & " ticks, or " & $sim.config.yieldOther &
    " of the other fruit every " & $sim.config.harvestCooldownOther &
    " ticks; a harvested tree is bare for " & $sim.config.regrowTicks &
    " ticks; hunger starts at " & $sim.config.hunger0 & " of " & $HungerMax &
    " and drops 1 every " & $sim.config.hungerDrainPeriod &
    " ticks; eating the fruit you crave restores " & $sim.config.craveNutrition &
    " hunger and scores " & $sim.config.craveScore & ", eating your own " &
    "restores " & $sim.config.ownNutrition & " and scores " &
    $sim.config.ownScore & "; you eat at most one fruit per " &
    $sim.config.eatCooldown & " ticks; entering a river cell costs " &
    $sim.config.moveStaminaWater & " stamina; at hunger 0 you lose " &
    $sim.config.starveDrain & " stamina per tick and at 0 stamina you cannot " &
    "move or harvest at all.\n\n")
  result.add("""THE STANDING ORDER: you choose a job for the next """ &
    $sim.config.ticksPerRound & """ ticks and a kernel walks it for you.
  harvest - go to the nearest ripe tree of a fruit and pick it
  market  - go to a named stall and stand there so your offer can clear
  trek    - cross to the FAR grove and pick the fruit you crave yourself
  rest    - stand still and let stamina regenerate

""")
  result.add("""TRADING: an offer is "I give X of one fruit, I want Y of the
other". An offer clears ONLY against its EXACT MIRROR held by a cog within """ &
    $sim.config.tradeRadius & """ cells: their give must be your want, with the
SAME two numbers, swapped. For example, if a cog near you offers *give 2
bananas, want 3 apples*, the only offer of yours that can clear with it is
*give 3 apples, want 2 bananas*. Nothing else clears, ever — not a better
price, not a bigger size. You may execute at most ONE trade per round, and an
executed offer is consumed. An offer you cannot cover from your inventory is
`unfunded`: everyone sees it and it never clears.

""")
  result.add("""SCORING: 5 points per craved fruit you eat, 1 point per own
fruit you eat; higher is better. Nothing else scores — not trades, not volume,
not harvests.

The other seven cogs are other policies deciding SIMULTANEOUSLY, right now,
with the same kind of information you have. NOBODY CAN HEAR ANYTHING YOU SAY:
your `say` line is for the spectators only. The only signals you can send
another cog are your POSTED OFFER and WHERE YOU STAND — the four named stalls
are the only meeting protocol there is. Your `notes` are private to you and are
handed back to you next round.

""")
  result.add("""OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }.""")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc rateText(x100: int): string =
  $(x100 div 100) & "." & align($(x100 mod 100), 2, '0')

proc userPrompt*(sim: Sim, slot: int, prompt: string): string =
  let
    cog = sim.cogs[slot]
    obs = sim.observationJson(slot)
    field = dijkstra(sim.board, cog.x, cog.y)
  result.add("ROUND " & $sim.roundOf() & " of " & $sim.config.rounds &
    " (tick " & $sim.tick & " of " & $sim.config.totalTicks() & ")\n\n")
  result.add("YOU: " & sim.aliases[slot] & ", " & $cog.farm & " farmer, at (" &
    $cog.x & "," & $cog.y & ") in the " & sim.zoneName(cog.x, cog.y) &
    ". apples " & $cog.apples & ", bananas " & $cog.bananas &
    ", hunger " & $cog.hunger & "/" & $HungerMax &
    ", stamina " & $cog.stamina & "/" & $StaminaMax &
    ", score " & $cog.score & ", trades " & $cog.trades & ".\n")
  result.add("YOUR STANDING OFFER: " &
    (if cog.offer.active:
      "give " & $cog.offer.giveN & " " & $cog.offer.giveFruit & ", want " &
        $cog.offer.wantN & " " & $cog.offer.wantFruit &
        (if cog.offer.unfunded: " (UNFUNDED - it cannot clear)" else: "")
    else: "(none)") & "\n\n")
  result.add("WHAT YOU CAN SEE (13x13, you are at the centre; . land, ~ water," &
    " # wall, A/a ripe/bare apple tree, B/b ripe/bare banana tree, S stall," &
    " 0-7 a cog by slot):\n")
  for row in sim.viewMap(slot):
    result.add("  " & row & "\n")
  result.add("\nNEARBY COGS (alias | cell | dist | their offer | mirrors you?)\n")
  var any = false
  for entry in obs["view"]["cogs"]:
    any = true
    let offerNode = entry["offer"]
    let offerText =
      if offerNode.kind == JNull: "(no offer)"
      else:
        "give " & $offerNode["give"]["n"].getInt & " " &
          offerNode["give"]["fruit"].getStr & ", want " &
          $offerNode["want"]["n"].getInt & " " &
          offerNode["want"]["fruit"].getStr &
          (if offerNode{"unfunded"}.getBool: " (unfunded)" else: "")
    result.add("  " & entry["alias"].getStr & " | (" &
      $entry["cell"][0].getInt & "," & $entry["cell"][1].getInt & ") | " &
      $entry["dist"].getInt & " | " & offerText & " | " &
      (if entry["mirrorsYou"].getBool: "YES" else: "no") & "\n")
  if not any:
    result.add("  (nobody within " & $sim.config.viewRadius & " cells)\n")
  result.add("\nSTALLS (walking distance from you)\n")
  for id in StallId:
    let d = sim.stallDistance(field, id)
    result.add("  " & $id & " at (" & $sim.board.stalls[id].x & "," &
      $sim.board.stalls[id].y & ") | " &
      (if d < 0: "unreachable" else: $d) & "\n")
  result.add("\nTHE TAPE (last executed trades on the whole board)\n")
  if sim.tape.len == 0:
    result.add("  (nothing has traded yet; the book price is 3 apples for " &
      "2 bananas = 1.50 apples/banana)\n")
  else:
    let first = max(0, sim.tape.len - TapeRows)
    for i in first ..< sim.tape.len:
      let row = sim.tape[i]
      result.add("  tick " & $row.t & " | " & $row.giveN & " " &
        $row.giveFruit & "s <-> " & $row.wantN & " " & $row.wantFruit &
        "s | " & rateText(row.applesPerBanana) & " apples/banana\n")
  result.add("\nYOUR ROUNDS SO FAR (round | score | hunger | stamina | " &
    "trades | harvested | eaten | crossings)\n")
  if sim.history[slot].len == 0:
    result.add("  (none yet)\n")
  else:
    for row in sim.history[slot]:
      result.add("  " & $row.round & " | " & $row.score & " | " & $row.hunger &
        " | " & $row.stamina & " | " & $row.trades & " | " & $row.harvested &
        " | " & $row.eaten & " | " & $row.crossings & "\n")
  result.add("\nYOUR NOTES FROM LAST ROUND:\n  " &
    (if cog.notes.len > 0: cog.notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"job\": one of harvest|market|trek|rest, " &
    "\"fruit\": apple|banana (optional), \"stall\": north|east|south|west " &
    "(optional), \"eat\": crave|any|none, \"offer\": " &
    "{\"give\":{\"fruit\":apple|banana,\"n\":" & $OfferMin & ".." &
    $sim.config.offerMax & "},\"want\":{\"fruit\":apple|banana,\"n\":" &
    $OfferMin & ".." & $sim.config.offerMax & "}} or null, \"say\": at most " &
    $MaxSayLen & " characters, \"notes\": at most " & $MaxNotesLen &
    " characters}.")

# ---- transport ---------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let
    start = text.find('{')
    stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(FruitMarketError,
      "no JSON object in response: " & head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 400s on it.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOfBody*(body: string): string =
  ## The text of a 2xx reply. A refusal and a `max_tokens` stop before any `{`
  ## both raise BY NAME — the max_tokens signature otherwise shows up as the
  ## misleading "unbalanced JSON object" (hanabi, 2026-08-24).
  let payload = parseJson(body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(FruitMarketError, "llm refusal")
  for contentBlock in payload{"content"}:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(FruitMarketError,
      "reply cut off at max_tokens mid-JSON: " &
      result[0 .. min(result.high, 160)].replace("\n", " "))

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(FruitMarketError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    client.disabled = true
    raise newException(FruitMarketError, "llm auth failed (" & $response.code &
      "): " & response.body[0 .. min(response.body.high, 300)])
  if response.code == 429:
    raise newException(FruitMarketError, "llm throttled (429): " &
      response.body[0 .. min(response.body.high, 200)])
  if response.code < 200 or response.code >= 300:
    raise newException(FruitMarketError, "llm error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 200)])
  textOfBody(response.body)

# ---- the reply schema --------------------------------------------------------

proc parseFruit(node: JsonNode, field: string): Fruit =
  case node.getStr().strip().toLowerAscii()
  of "apple": fApple
  of "banana": fBanana
  else:
    raise newException(FruitMarketError,
      "unknown fruit in " & field & ": " & $node)

proc offerCount(node: JsonNode, config: GameConfig):
    tuple[value: int, clamped: bool] =
  var raw: int
  case node.kind
  of JInt:
    raw = node.getInt()
  of JString:
    try:
      raw = parseInt(node.getStr().strip())
    except ValueError:
      raise newException(FruitMarketError, "offer n is not an integer: " & $node)
  else:
    raise newException(FruitMarketError, "offer n must be an integer: " & $node)
  clampOfferN(config, raw)

proc parseOrder*(payload: JsonNode, sim: Sim, slot: int): Order =
  ## Tolerant parse of one reply. Anything the table in the design note marks
  ## "invalid reply" raises; `n` outside the range is CLAMPED and flagged.
  let cog = sim.cogs[slot]
  result.source = osLlm
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen)

  let jobNode = payload{"job"}
  if jobNode.isNil or jobNode.kind != JString:
    raise newException(FruitMarketError, "no job in reply")
  case jobNode.getStr().strip().toLowerAscii()
  of "harvest": result.job = jHarvest
  of "market": result.job = jMarket
  of "trek": result.job = jTrek
  of "rest": result.job = jRest
  else:
    raise newException(FruitMarketError, "unknown job: " & jobNode.getStr())

  let fruitNode = payload{"fruit"}
  if not fruitNode.isNil and fruitNode.kind == JString and
      fruitNode.getStr().strip().len > 0:
    result.fruit = parseFruit(fruitNode, "fruit")
    result.hasFruit = true
  else:
    result.fruit = if result.job == jTrek: cog.craved() else: cog.farm
    result.hasFruit = false

  let stallNode = payload{"stall"}
  if not stallNode.isNil and stallNode.kind == JString and
      stallNode.getStr().strip().len > 0:
    case stallNode.getStr().strip().toLowerAscii()
    of "north": result.stall = stNorth
    of "east": result.stall = stEast
    of "south": result.stall = stSouth
    of "west": result.stall = stWest
    else:
      raise newException(FruitMarketError, "unknown stall: " & stallNode.getStr())
    result.hasStall = true

  let eatNode = payload{"eat"}
  if eatNode.isNil or eatNode.kind != JString or eatNode.getStr().len == 0:
    result.eat = epAny
  else:
    case eatNode.getStr().strip().toLowerAscii()
    of "crave": result.eat = epCrave
    of "any": result.eat = epAny
    of "none": result.eat = epNone
    else:
      raise newException(FruitMarketError, "unknown eat: " & eatNode.getStr())

  if payload.hasKey("offer"):
    result.hasOfferKey = true
    let offerNode = payload["offer"]
    if offerNode.kind == JNull:
      result.withdraw = true
    else:
      if offerNode.kind != JObject or not offerNode.hasKey("give") or
          not offerNode.hasKey("want"):
        raise newException(FruitMarketError, "offer must be an object with " &
          "give and want, or null")
      let
        give = offerNode["give"]
        want = offerNode["want"]
      if give.kind != JObject or want.kind != JObject:
        raise newException(FruitMarketError, "offer give/want must be objects")
      let
        giveFruit = parseFruit(give{"fruit"}, "offer.give.fruit")
        wantFruit = parseFruit(want{"fruit"}, "offer.want.fruit")
      if giveFruit == wantFruit:
        raise newException(FruitMarketError,
          "offer give.fruit and want.fruit must differ")
      let
        giveN = offerCount(give{"n"}, sim.config)
        wantN = offerCount(want{"n"}, sim.config)
      result.offer = Offer(active: true,
        giveFruit: giveFruit, giveN: giveN.value,
        wantFruit: wantFruit, wantN: wantN.value)
      result.clamped = giveN.clamped or wantN.clamped

proc buildBatch*(
  client: LlmClient,
  sim: Sim,
  prompts: array[Seats, string],
  open: seq[int],
  attempt: int
): RequestBatch =
  ## ONE request per open seat, in ONE batch. Decisions inside a round are
  ## simultaneous by rule, so `decideAll` issues this whole batch in parallel;
  ## a sequential sweep would blow the play budget. tests/test_llm.nim asserts
  ## `buildBatch(...).len == openSeats`.
  for slot in open:
    var user = sim.userPrompt(slot, prompts[slot])
    if attempt > 0:
      user.add(RetryHint)
    let request = client.requestFor(sim.systemPrompt(slot), user)
    result.post(request.url, request.headers, request.body, $slot)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  prompts: array[Seats, string],
  scripted: array[Seats, ScriptKind],
  connected: array[Seats, bool]
): array[Seats, Order] =
  ## One standing order per seat. NEVER raises: any failure falls back to the
  ## `hauler` order so the episode always advances.
  var open: seq[int]
  for slot in 0 ..< Seats:
    let kind = scripted[slot]
    if kind != skNone or client.disabled or not connected[slot]:
      result[slot] = scriptedOrder(sim, slot,
        (if kind == skNone: skHauler else: kind))
    else:
      open.add(slot)

  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    let started = epochTime()
    var batch = client.buildBatch(sim, prompts, open, attempt)
    ## ONE parallel batch for the whole round — this is a simultaneous-decision
    ## game and a sequential sweep would blow the play budget.
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    let latency = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, slot in open:
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var order = parseOrder(extractJsonObject(text), sim, slot)
        order.source = if attempt == 0: osLlm else: osRetry
        order.latencyMs = latency
        result[slot] = order
      except CatchableError as error:
        echo "fruit-market llm: seat ", slot, " attempt ", attempt,
          " failed: ", cleanText(error.msg, MaxErrorLen)
        stillOpen.add(slot)
    open = stillOpen

  for slot in open:
    echo "fruit-market llm: seat ", slot, " falling back to scripted order"
    result[slot] = scriptedOrder(sim, slot, skHauler)
    result[slot].source = osFallback
