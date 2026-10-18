## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "fruit-market-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, fruit: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", a " & fruit & " farmer in Fruit Market."
  of pvPlain: "In Fruit Market, you play " & alias & ". You farm " & fruit & "."
  of pvNumbered: "1. Game: Fruit Market. 2. Your identity: " & alias & ". 3. Your farm: " & fruit & "."
  of pvQuestions: "What are you playing? Fruit Market. Who are you? " & alias & ". What do you farm? " & fruit & "."
  of pvReordered: "As a " & fruit & " farmer named " & alias & ", you play Fruit Market."
  of pvHeldoutBriefing: "Take the role of " & alias & " in Fruit Market, where you are a " & fruit & " farmer."
  of pvHeldoutReference: "Game: Fruit Market. Farmer identity: " & alias & ". Farm type: " & fruit & "."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
