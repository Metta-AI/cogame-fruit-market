## Export complete Fruit Market games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import fruit_market/[sim_types, sim_config, sim_state, scripted, sim, llm]

const OperatorPrompt = "Maximize your own score by farming, trading, and eating fruit you crave."
const Variants = ["open-market", "concentric-rivers", "deep-rivers",
  "lean-harvest"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for slot in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $slot))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let view = game
      var orders: array[Seats, Order]
      for slot in 0 ..< Seats:
        let teacher = scriptedOrder(view, slot, skHauler)
        doAssert teacher.hasOfferKey and teacher.offer.active
        var completion = %*{
          "job": $teacher.job, "eat": $teacher.eat,
          "offer": {
            "give": {"fruit": $teacher.offer.giveFruit,
              "n": teacher.offer.giveN},
            "want": {"fruit": $teacher.offer.wantFruit,
              "n": teacher.offer.wantN}
          },
          "say": teacher.say, "notes": teacher.notes
        }
        if teacher.hasFruit:
          completion["fruit"] = %($teacher.fruit)
        if teacher.hasStall:
          completion["stall"] = %($teacher.stall)
        var parsed = parseOrder(completion, view, slot)
        doAssert parsed.job == teacher.job
        doAssert parsed.eat == teacher.eat
        doAssert parsed.hasFruit == teacher.hasFruit
        doAssert parsed.hasStall == teacher.hasStall
        doAssert parsed.offer == teacher.offer
        doAssert parsed.say == teacher.say
        if teacher.hasFruit:
          doAssert parsed.fruit == teacher.fruit
        if teacher.hasStall:
          doAssert parsed.stall == teacher.stall
        parsed.source = osScripted
        orders[slot] = parsed
        rows.add($(%*{
          "episode_id": "fruit-market-" & variant & "-" & $seed,
          "seed": "fruit-market-" & variant & "-" & $seed,
          "decision_id": view.round * Seats + slot,
          "prompt": [
            {"role": "system", "content": systemPrompt(view, slot)},
            {"role": "user", "content": userPrompt(view, slot,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "fruit-market",
          "action_schema_revision": "fruit-market-order-v1"
        }))
      game.setRoundOrders(orders)
      game.runRound()
    doAssert game.reason == "complete" and rows.len > 0
    let outcome = game.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds": outcome["rounds"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "fruit-market",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-hauler",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
