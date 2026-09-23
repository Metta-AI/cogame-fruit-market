# Metta post-training data

The native simulator and published `hauler` policy export supervised examples
for all four certified Fruit Market variants:

```sh
nimby sync nimby.lock
for variant in open-market concentric-rivers deep-rivers lean-harvest; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/fruit-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games. The exporter freezes the game state at each simultaneous round, then
records each seat's hosted system and user prompts and a `hauler` order
accepted by the game's reply parser. Parsed orders drive the simulator. Whole
games stay in one split. The manifest records source revision, variant,
scores, rounds, and row counts. Existing output directories are never
overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/fruit-open-market \
  --output /tmp/fruit-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games per variant yielded 3,840 examples. Every example fit the
Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 1,986. One
CPU optimizer step per variant with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

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
