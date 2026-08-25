## tests/test_manifest.nim — packaging.
##
## Everything the platform validator and `coworld build` check that repo CI can
## check first. A manifest edited without the design note — or the other way
## round — is caught here rather than at phase 40.

import std/[json, os, sets, strutils, unittest]

import fruit_market/sim

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc readManifest(): JsonNode =
  parseJson(readFile(RepoRoot / "coworld_manifest_template.json"))

suite "the manifest template":
  let manifest = readManifest()
  let game = manifest["game"]

  test "num_agents is 8 in EVERY variant and in the certification fixture":
    check manifest["variants"].len == 4
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == Seats
      check variant.hasKey("description")
      check variant["description"].getStr().len > 20
      check variant["game_config"]["players"].len == Seats
    check manifest["certification"]["game_config"]["num_agents"].getInt() == Seats
    check manifest["certification"]["players"].len == Seats
    check manifest["certification"]["game_config"]["players"].len == Seats

  test "the four variant ids are the four the design names":
    var ids: seq[string]
    for variant in manifest["variants"]:
      ids.add(variant["id"].getStr())
    check ids == @["open-market", "concentric-rivers", "deep-rivers",
      "lean-harvest"]

  test "the image placeholder is the one compose.yaml's service name derives":
    ## `coworld build` derives the placeholder from the COMPOSE SERVICE NAME:
    ## service `fruit_market` -> {{FRUIT_MARKET_IMAGE}}. {{GAME_IMAGE}} is not
    ## a thing (lantern, 2026-08-23).
    let compose = readFile(RepoRoot / "compose.yaml")
    var service = ""
    for line in compose.splitLines():
      let trimmed = line.strip()
      if trimmed.endsWith(":") and line.startsWith("  ") and
          not line.startsWith("    ") and trimmed.len > 1:
        service = trimmed[0 ..< trimmed.len - 1]
        break
    check service == "fruit_market"
    let placeholder = "{{" & service.toUpperAscii() & "_IMAGE}}"
    check placeholder == "{{FRUIT_MARKET_IMAGE}}"
    check game["runnable"]["image"].getStr() == placeholder
    check "image: coworld-fruit-market:latest" in compose
    check "platform: linux/amd64" in compose
    for player in manifest["player"]:
      check player["image"].getStr() == placeholder

  test "replays are a static bundle, never a pod":
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check not manifest.hasKey("version")
    check not game.hasKey("display_name")
    check game.hasKey("owner")
    check fileExists(RepoRoot / "tools" / "build_replay_viewer.sh")

  test "game.name matches the secret namespace and the repo slug":
    check game["name"].getStr() == "fruit-market"
    let uri = game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
    check uri == "secret://coworld/" & game["name"].getStr() & "/anthropic_api_key"
    check game["runnable"]["type"].getStr() == "game"
    check game["runnable"]["run"][0].getStr() == "/bin/fruit-market"

  test "docs are text objects with a readme and non-empty pages":
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["readme"]["value"].getStr().len > 200
    check game["docs"]["pages"].len >= 2
    for page in game["docs"]["pages"]:
      check page.hasKey("id")
      check page.hasKey("title")
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200

  test "both protocols are present and both are text objects":
    ## The platform validator rejects bare strings (garble v0.1.0).
    for key in ["player", "global"]:
      check game["protocols"].hasKey(key)
      check game["protocols"][key]["type"].getStr() == "text"
      check game["protocols"][key]["value"].getStr().len > 200

  test "every declared player entry is seated at least once":
    ## `players-run` seats the whole roster; a baseline x N fixture fails
    ## players_missing (raid, 2026-08-23).
    var declared = initHashSet[string]()
    for player in manifest["player"]:
      declared.incl(player["id"].getStr())
      check player["type"].getStr() == "player"
      check player["run"][0].getStr() == "/bin/fruit-market-player"
    var seated = initHashSet[string]()
    for row in manifest["certification"]["players"]:
      seated.incl(row["player_id"].getStr())
    check declared == seated
    check declared.len == 3
    ## 2 x prompt player + 4 x hauler + 2 x homesteader.
    var counts = [0, 0, 0]
    for row in manifest["certification"]["players"]:
      case row["player_id"].getStr()
      of "fruit-market-player": counts[0].inc
      of "fruit-market-hauler": counts[1].inc
      else: counts[2].inc
    check counts == [2, 4, 2]

  test "the certification fixture declares no runner-managed tokens":
    ## collab-cooking, 2026-08-25: manifest_invalid otherwise.
    check not manifest["certification"]["game_config"].hasKey("tokens")
    check manifest["certification"]["game_config"]["minTurnSeconds"].getInt() == 0
    ## 6 x 60 ticks = 360 ticks = 15 s of video, which outlasts the 10 s
    ## viewer soak (ecos, 2026-08-23).
    check manifest["certification"]["game_config"]["rounds"].getInt() == 6
    check manifest["certification"]["game_config"]["ticksPerRound"].getInt() == 60

  test "episode_timeout_minutes is top level and the tags are real":
    check manifest["episode_timeout_minutes"].getInt() == 20
    check manifest["tags"].len >= 3
    check manifest.hasKey("$schema")

  test "every array property in config_schema carries minItems and maxItems":
    ## tandem 0.1.0, 2026-08-23: bounds on EVERY array, not just required ones.
    let props = game["config_schema"]["properties"]
    var arrays = 0
    for name, spec in props:
      if spec{"type"}.getStr() == "array":
        arrays.inc
        check spec.hasKey("minItems")
        check spec.hasKey("maxItems")
    check arrays >= 2
    check game["config_schema"]["additionalProperties"].getBool() == false
    check game["config_schema"]["required"][0].getStr() == "tokens"

  test "the config schema and the sim agree on every default it names":
    let props = game["config_schema"]["properties"]
    let config = defaultGameConfig()
    check props["num_agents"]["default"].getInt() == config.numAgents
    check props["rounds"]["default"].getInt() == config.rounds
    check props["ticksPerRound"]["default"].getInt() == config.ticksPerRound
    check props["invCap"]["default"].getInt() == config.invCap
    check props["eatCooldown"]["default"].getInt() == config.eatCooldown
    check props["harvestCooldownOwn"]["default"].getInt() ==
      config.harvestCooldownOwn
    check props["harvestCooldownOther"]["default"].getInt() ==
      config.harvestCooldownOther
    check props["tradeRadius"]["default"].getInt() == config.tradeRadius
    check props["viewRadius"]["default"].getInt() == config.viewRadius
    check props["offerMax"]["default"].getInt() == config.offerMax
    check props["llmTimeoutSeconds"]["default"].getInt() ==
      config.llmTimeoutSeconds
    check props["minTurnSeconds"]["default"].getInt() == config.minTurnSeconds
    check props["maxOutputTokens"]["default"].getInt() ==
      config.maxOutputTokens
    check props["shutdownGraceSeconds"]["default"].getInt() ==
      config.shutdownGraceSeconds

  test "each variant's game_config resolves to its own variant id":
    for variant in manifest["variants"]:
      var config = defaultGameConfig()
      config.update($variant["game_config"])
      check config.variantId() == variant["id"].getStr()
      check config.numAgents == Seats

  test "the results schema names every field results.json writes":
    var config = defaultGameConfig()
    config.seed = 1
    let results = initSim(config).resultsJson()
    let props = game["results_schema"]["properties"]
    for key, _ in results:
      check props.hasKey(key)

suite "the CI policy set":
  let policies = parseJson(readFile(RepoRoot / "tools" / "ci" / "policies.json"))

  test "two prompt champions and two scripted fillers, all one image":
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/fruit-market-player"
      check policy["name"].getStr().startsWith("fruit-market-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        prompts.inc
        ## Without USE_BEDROCK the platform gives the player pod no Bedrock
        ## sidecar and the seat silently plays scripted (cogolf, 2026-08-24).
        check policy["env"]["USE_BEDROCK"].getStr() == "true"
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      else:
        scripted.inc
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["hauler", "homesteader"]
    check prompts == 2
    check scripted == 2

  test "champion #2 is uploaded as daveey-1":
    check policies[1]["name"].getStr() == "fruit-market-ricardo"
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")

  test "the two champion prompts are different policies":
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()
