# Prompt diversity

The native host, language bridge, and teacher exporter share five training
wordings and two evaluation-only wordings. Bank `fruit-market-rules-v2` varies
exact-mirror trading, funding, scoring, simultaneous decisions, and communication.
Board constants, private farmer types, action grammar, and canonical messages
remain unchanged.

Set `promptVariant` to `canonical` (default), `plain`, `numbered`, `questions`,
`reordered`, or `mixed`. Mixed selection requires a nonnegative `promptSeed`;
`promptSeed % 5` selects a training wording without consuming simulator randomness.
Selection stays fixed during each episode. `heldout-briefing` and
`heldout-reference` are evaluation-only; train resets and teacher exports reject them.

## Language actions and exports

```sh
nim c -d:release --path:src -o:/tmp/fruit-market-bridge tools/train_bridge.nim
/tmp/fruit-market-bridge coworld_manifest_template.json open-market text
nim c -d:release --path:src -o:/tmp/fruit-market-export tools/export_posttrain.nim
/tmp/fruit-market-export /tmp/fruit-data 10 1 open-market mixed 0
```

The `text` bridge accepts the complete native order schema, including spectator
speech, private notes, and omitted/null offers. All eight orders are collected
before installation. Accepted replies report parser-normalized orders.
Private observations include wording metadata and rendered-message hashes.
Spectator speech never reaches another player's prompt.

Exports retain `train.jsonl`, `validation.jsonl`, and `manifest.json`, with source
revision, complete-game outcomes, message hashes, and per-game wording selection.
Mixed exports cycle through five training wordings separately within each split.
Episode IDs include requested selection, resolved wording, and prompt seed
for matched collections. Keep each `fruit-market-SEED`
family together across board variants and wordings to prevent split leakage.
Original arguments remain valid; omit wording and prompt seed for canonical exports.

## Validation

`tools/test_prompt_games.py BRIDGE` plays 40 complete wording and normalization
games across all four published variants. `tools/test_export_posttrain.py EXPORTER`
checks 40 complete mixed exports and family separation. The existing
`tools/test_train_bridge.py BRIDGE` covers numeric teacher and random games.
Existing hosted-request checks cover the shared renderer and parallel batching.

Compare canonical and mixed training with matched seeds, seats, opponents, and
inference settings. Measure win rate, invalid-order rate, fallback rate, request
counts, and completion rates on familiar and held-out wording. These local checks
do not establish learned robustness or live-provider performance.

## Native private capture

The hosted server writes the bitworld decision-trajectory format when the runtime
supplies `COGAME_SAVE_TRAJECTORY_URI` and immutable episode/version/source identity.
It retains exact parallel native requests, received body bytes and headers,
platform call IDs, retries, seat-private observations and operator guidance.
Attempt latency is parallel batch wall time, an upper bound for each response;
use authenticated call receipts for per-call latency. The
simulator records the actual applied order after installation. Scripted teachers,
unknown external players and engine fallbacks remain distinct; scripted policies
are not automatically approved as teachers. No private request enters spectator
replays or changes the existing player interface.

Parser-normalized proposals remain visible with their original parsed fields and
actual applied action, but have no selected training target. They are rejected
targets, not substituted baseline actions. The native JSON parser, decoder,
simultaneous batch timing, game rules and default turn limits are unchanged.

Native family identity hashes the initial farm allocation, derived geography and
all consequential physical configuration. Only initialization consumes the farm
shuffle RNG. Seeds producing the same farms and rules stay together across
policies, aliases and wordings. The private family hash reveals no hidden farmer
types to a player. Historical offline exports above retain their original seed
labels and source pins; audit those labels before claiming independent evaluation.

Run complete local native fixtures with compiled game/player binaries:

```sh
python3 tools/test_native_capture.py /path/to/fruit-market /path/to/fruit-market-player /new/private/output
# Other complete cohorts: --mode invalid, --mode 429, --mode normalized, --no-capture.
nim c -d:release --path:src -o:/tmp/fruit-market-verify tools/verify_native_capture.nim
/tmp/fruit-market-verify /new/private/output/config.json /new/private/output/trajectory.jsonl
/tmp/fruit-market-verify --families
```

The independent native reconstruction regenerates every captured seat observation,
rendered message, applied order and terminal outcome through production source.
Fixtures use loopback-only synthetic provider responses and no real credentials;
their IDs are never authenticated receipts or learning examples. Fresh complete
hosted model games, archived receipt admission, target-quality review and frozen
physical-family/partner evaluation are still required for posttraining readiness.

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
