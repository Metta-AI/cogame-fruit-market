# Prompt diversity and candidate trajectories

The native host, language bridge, and teacher exporter share five training
introductions and two held-out introductions. Canonical wording preserves the
original messages. Shared rules, private farmer types, action schema, simulator
randomness, simultaneous orders, and published budgets remain unchanged.

Set game configuration `promptVariant` to `canonical` (default), `plain`,
`numbered`, `questions`, `reordered`, or `mixed`. Mixed selection requires a
nonnegative `promptSeed`; `promptSeed % 5` chooses a training introduction.
Selection remains fixed throughout the episode. `heldout-briefing` and
`heldout-reference` are evaluation-only; the bridge rejects them for `split:
"train"`, and the teacher exporter rejects them.

## Complete language actions

```sh
nim c -d:release --path:src -o:/tmp/fruit-market-bridge tools/train_bridge.nim
/tmp/fruit-market-bridge coworld_manifest_template.json open-market text
```

The optional `text` argument enables the complete native order schema, including
spectator speech, private player notes, and omitted/null offers. All eight
orders are collected before installation. The bridge returns the parsed order,
including quantity clamping, so collection records what the engine accepted.
Private observations include wording identity and SHA-256 hashes of rendered
system/user messages. Spectator speech never reaches another player's prompt.

## Reviewed candidate export

From a clean, committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/fruit-market-export tools/export_posttrain.nim
/tmp/fruit-market-export /tmp/fruit-candidates 10 1 open-market plain 0
```

Other published variants are `concentric-rivers`, `deep-rivers`, and
`lean-harvest`. Omit the last two arguments for canonical wording. The exporter
streams private `trajectories.jsonl`, `execution.jsonl`, and `manifest.json`.
Each complete game contains exact prompts, `hauler` proposals, parsed orders,
actual kernel actions, replay frames/events, outcomes, and source revision.

These are candidates, not approved training labels. The shared Coworld
importer owns independent review and dataset splitting. Keep each
`fruit-market-SEED` family together across variants and wordings.

## Native evidence and evaluation

Set `FRUIT_MARKET_HOST_TRACE_PATH`, `FRUIT_MARKET_ATTEMPT_TRACE_DIR`, and
`FRUIT_MARKET_SOURCE_REVISION` to retain private native evidence. Attempt files
record actual request bodies, model identity, responses, failures, parsing,
and retry selection. Host records join installed orders with tick execution.
These artifacts are separate from spectator replay data. Authentication
headers are not recorded.

Run complete workflow checks with `tools/test_prompt_games.py BRIDGE
ORIGINAL_BRIDGE`, `tools/test_export_posttrain.py EXPORTER`, and
`tools/test_native_prompts.py GAME PLAYER OUTPUT`. The native panel retains
published budgets and pacing. It uses a reserved closed inference endpoint
and real host/player processes to verify failed requests and fallback paths.
`--smoke` selects two canonical native cases.

For learning comparisons, match game seeds, seats, opponents, and inference
settings between canonical and mixed training. Report win rate, invalid-order
rate, fallback rate, request counts, and completion rate for familiar and
held-out wording. Deterministic checks do not establish learning stability or
successful provider inference.

# Numeric reinforcement learning

Compile the persistent bridge and pass the binary, manifest, and variant to
Metta's `recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/fruit-market-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/fruit-market-train-bridge
```

All four certified variants expose 326 numeric observation values and five
factorized action heads: job (4 choices), fruit (default, apple, banana),
stall (default plus four stalls), eat (3), and offer (keep, withdraw, or 72
bounded give/want contracts). The observation uses the same per-seat view as
the hosted prompt: own state, local map and visible offers, public stalls,
and own recent history. Hidden opponent state remains hidden. Each decision
uses the native reply parser, and the simulator advances only after all eight
seats submit standing orders. The published hauler supplies teacher actions.
The numeric policy omits spectator text and private notes; the post-training
exporter retains them.
