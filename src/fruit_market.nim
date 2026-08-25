## Fruit Market entrypoint: reads the Coworld runtime contract and starts the
## episode server.
##
## Forked from coworld-ctf `src/ctf.nim`. The seed is randomised BEFORE
## `config.update`, because every seed-derived draw — including the farm-type
## shuffle that assigns who grows what — must follow the final seed.

import
  std/[json, sysrand],
  bitworld/runtime,
  fruit_market/sim,
  fruit_market/server

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(FruitMarketError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

proc stripSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    config.seed = randomSeed()
    config.update(stripSeed(runtimeConfig.config))
    echo "fruit-market: seed not pinned; randomized"

  ## The runner injects one token per seat; without them nothing can connect.
  if config.tokens.len == 0:
    for slot in 0 ..< config.numAgents:
      config.tokens.add("token-" & $slot)
  while config.players.len < config.numAgents:
    config.players.add(PlayerConfig(name: CogAliases[config.players.len]))

  echo "fruit-market: variant=", config.variantId(),
    " seats=", config.numAgents,
    " rounds=", config.rounds,
    " ticksPerRound=", config.ticksPerRound,
    " seed=", config.seed
  runGameServer(config, runtimeConfig)
