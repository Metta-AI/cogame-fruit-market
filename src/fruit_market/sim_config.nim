## GameConfig lifecycle and `config.update`.
##
## Fork of coworld-ctf `src/ctf/sim_config.nim`, reduced to the fields the
## manifest's `game.config_schema` declares. Nothing here is optional: the CLI
## validates every variant and the certification fixture against that schema,
## so a field the schema names and this module ignores is a silently dead knob.

import std/[json, strutils]

import ./sim_types

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    numAgents*: int
    seed*: int
    rivers*: int
    rounds*: int
    ticksPerRound*: int
    moveCooldown*: int
    waterMoveCooldown*: int
    moveStaminaWater*: int
    moveStaminaLand*: int
    harvestCooldownOwn*: int
    harvestCooldownOther*: int
    yieldOwn*: int
    yieldOther*: int
    regrowTicks*: int
    invCap*: int
    hunger0*: int
    hungerDrainPeriod*: int
    craveNutrition*: int
    ownNutrition*: int
    craveScore*: int
    ownScore*: int
    eatCooldown*: int
    starveDrain*: int
    staminaRegenPeriod*: int
    tradeRadius*: int
    viewRadius*: int
    offerMax*: int
    llmTimeoutSeconds*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: Seats,
    seed: 0,
    rivers: 2,
    rounds: Rounds,
    ticksPerRound: TicksPerRound,
    moveCooldown: MoveCooldown,
    waterMoveCooldown: WaterMoveCooldown,
    moveStaminaWater: MoveStaminaWater,
    moveStaminaLand: MoveStaminaLand,
    harvestCooldownOwn: HarvestCooldownOwn,
    harvestCooldownOther: HarvestCooldownOther,
    yieldOwn: YieldOwn,
    yieldOther: YieldOther,
    regrowTicks: RegrowTicks,
    invCap: InvCap,
    hunger0: Hunger0,
    hungerDrainPeriod: HungerDrainPeriod,
    craveNutrition: CraveNutrition,
    ownNutrition: OwnNutrition,
    craveScore: CraveScore,
    ownScore: OwnScore,
    eatCooldown: EatCooldown,
    starveDrain: StarveDrain,
    staminaRegenPeriod: StaminaRegenPeriod,
    tradeRadius: TradeRadius,
    viewRadius: ViewRadius,
    offerMax: OfferMax,
    llmTimeoutSeconds: 20,
    minTurnSeconds: 18,
    maxOutputTokens: 1000,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20,
    showPlayerLabels: true
  )

proc variantId*(config: GameConfig): string =
  ## The manifest variant this config resolves to. Derived, never configured:
  ## `game.config_schema` sets `additionalProperties: false`, so a `variant`
  ## key would be rejected by the platform validator.
  if config.rivers <= 0: "open-market"
  elif config.regrowTicks >= 90: "lean-harvest"
  elif config.moveStaminaWater >= 18: "deep-rivers"
  else: "concentric-rivers"

proc getIntField(node: JsonNode, key: string, current: int): int =
  if node.hasKey(key) and node[key].kind in {JInt, JFloat}:
    node[key].getInt()
  else:
    current

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(FruitMarketError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  config.numAgents = node.getIntField("num_agents", config.numAgents)
  config.seed = node.getIntField("seed", config.seed)
  config.rivers = node.getIntField("rivers", config.rivers)
  config.rounds = node.getIntField("rounds", config.rounds)
  config.ticksPerRound = node.getIntField("ticksPerRound", config.ticksPerRound)
  config.moveCooldown = node.getIntField("moveCooldown", config.moveCooldown)
  config.waterMoveCooldown =
    node.getIntField("waterMoveCooldown", config.waterMoveCooldown)
  config.moveStaminaWater =
    node.getIntField("moveStaminaWater", config.moveStaminaWater)
  config.moveStaminaLand =
    node.getIntField("moveStaminaLand", config.moveStaminaLand)
  config.harvestCooldownOwn =
    node.getIntField("harvestCooldownOwn", config.harvestCooldownOwn)
  config.harvestCooldownOther =
    node.getIntField("harvestCooldownOther", config.harvestCooldownOther)
  config.yieldOwn = node.getIntField("yieldOwn", config.yieldOwn)
  config.yieldOther = node.getIntField("yieldOther", config.yieldOther)
  config.regrowTicks = node.getIntField("regrowTicks", config.regrowTicks)
  config.invCap = node.getIntField("invCap", config.invCap)
  config.hunger0 = node.getIntField("hunger0", config.hunger0)
  config.hungerDrainPeriod =
    node.getIntField("hungerDrainPeriod", config.hungerDrainPeriod)
  config.craveNutrition =
    node.getIntField("craveNutrition", config.craveNutrition)
  config.ownNutrition = node.getIntField("ownNutrition", config.ownNutrition)
  config.craveScore = node.getIntField("craveScore", config.craveScore)
  config.ownScore = node.getIntField("ownScore", config.ownScore)
  config.eatCooldown = node.getIntField("eatCooldown", config.eatCooldown)
  config.starveDrain = node.getIntField("starveDrain", config.starveDrain)
  config.staminaRegenPeriod =
    node.getIntField("staminaRegenPeriod", config.staminaRegenPeriod)
  config.tradeRadius = node.getIntField("tradeRadius", config.tradeRadius)
  config.viewRadius = node.getIntField("viewRadius", config.viewRadius)
  config.offerMax = node.getIntField("offerMax", config.offerMax)
  config.llmTimeoutSeconds =
    node.getIntField("llmTimeoutSeconds", config.llmTimeoutSeconds)
  config.minTurnSeconds =
    node.getIntField("minTurnSeconds", config.minTurnSeconds)
  config.maxOutputTokens =
    node.getIntField("maxOutputTokens", config.maxOutputTokens)
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  config.episodeTimeoutSeconds =
    node.getIntField("episodeTimeoutSeconds", config.episodeTimeoutSeconds)
  config.playerConnectTimeoutSeconds = node.getIntField(
    "playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds)
  config.playerConnectTimeoutSeconds = node.getIntField(
    "player_connect_timeout_seconds", config.playerConnectTimeoutSeconds)
  config.shutdownGraceSeconds =
    node.getIntField("shutdownGraceSeconds", config.shutdownGraceSeconds)
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool()

  ## curl's CURLOPT_TIMEOUT floors a sub-second deadline to whole seconds, so a
  ## fractional deadline silently becomes a different number (paintball,
  ## 2026-08-25). Reject it here rather than let it round in the transport.
  if node.hasKey("llmTimeoutSeconds") and
      node["llmTimeoutSeconds"].kind == JFloat and
      node["llmTimeoutSeconds"].getFloat() != node["llmTimeoutSeconds"].getFloat().int.float:
    raise newException(FruitMarketError,
      "llmTimeoutSeconds must be a whole number of seconds")
  if config.llmTimeoutSeconds < 1:
    raise newException(FruitMarketError,
      "llmTimeoutSeconds must be at least 1 second")
  if config.rounds < 1:
    raise newException(FruitMarketError, "rounds must be at least 1")
  if config.ticksPerRound < 1:
    raise newException(FruitMarketError, "ticksPerRound must be at least 1")
  if config.numAgents < 1 or config.numAgents > Seats:
    raise newException(FruitMarketError,
      "num_agents must be 1.." & $Seats)
  if config.offerMax < OfferMin:
    raise newException(FruitMarketError, "offerMax must be at least 1")

proc totalTicks*(config: GameConfig): int =
  config.rounds * config.ticksPerRound
