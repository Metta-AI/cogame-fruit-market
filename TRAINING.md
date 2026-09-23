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
