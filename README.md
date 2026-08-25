# Fruit Market

**Apple farmers who crave bananas, banana farmers who crave apples, and offers
that only clear when they mirror.**

Eight cogs share one walled 32 × 18 board. Four of them farm apples, four farm
bananas, and which is which is dealt from the episode seed — nobody is told
anybody else's type. You score **five points** for eating a fruit you do not
grow and **one** for eating your own, so everybody wants what everybody else
has and nobody can just farm their way to a win.

The board is four concentric belts: the apple grove on the outside, then a
river, then the market ring with four named stalls (`NORTH`, `EAST`, `SOUTH`,
`WEST`), then another river, then the banana island. Your own grove pays three
fruit a harvest; the far grove pays one, at a fifth of the rate, for ten stamina
of river tolls each way. Walking across to pick the fruit you crave is a real
option and a bad trade.

The cheap way to get what you crave is a **posted offer** — and an offer clears
only against its **exact mirror**: their give must be your want, with the same
two numbers, swapped, held by a cog within three cells. Not a better price. Not
a bigger size. One trade per cog per round, and an executed offer is consumed.

**Nobody can talk.** The offer is the message and the four stalls are the only
meeting protocol there is. That is comparative advantage, bargaining and price
discovery with no words — with a hunger bar over every cog saying what a failed
trade costs.

## A policy is just a prompt

```bash
coworld upload-policy coworld-fruit-market:latest \
  --name my-fruit-market \
  --run /bin/fruit-market-player \
  --secret-env PLAYER_PROMPT="You are a market maker, not a farmer. ..."
```

The player process connects, sends one `{"type":"prompt", …}` frame and then
only listens. Every decision is made inside the **game** container, which asks
the model for all eight seats' standing orders as **one parallel batch per
round** — a simultaneous-decision game decided simultaneously. One image also
carries both scripted baselines, selected by env var:

| env | seat plays |
| --- | --- |
| `PLAYER_PROMPT="<strategy in words>"` | an LLM seat |
| `PLAYER_SCRIPTED=hauler` | the market maker: bank three of your own fruit, walk to the round's rendezvous stall, post the book price (three of yours for two of theirs) |
| `PLAYER_SCRIPTED=homesteader` | the autarky foil: never trade, farm your own grove, trek across both rivers for the fruit you crave |
| neither | `hauler` |

## The standing order

One round is 60 ticks. Once per round a seat answers with exactly one JSON
object and a deterministic kernel walks it for the whole round:

```json
{"job":"market","stall":"north","eat":"crave",
 "offer":{"give":{"fruit":"apple","n":3},"want":{"fruit":"banana","n":2}},
 "say":"mirroring Ash at the north stall - 3 apples for 2 bananas",
 "notes":"Ash is a banana farmer and posts 2-for-3 every round"}
```

`job` is `harvest | market | trek | rest`; `eat` is `crave | any | none`; the
`offer` key being absent leaves your standing offer alone and `null` withdraws
it; `n` outside 1..6 is clamped and flagged. `say` is **spectator only** — it is
drawn in the viewer and recorded in the replay and never reaches another seat.
`notes` are private and handed back to you next round. Full schema:
`coworld_manifest_template.json` → `game.docs.pages[policies.md]`.

## Layout

| path | what |
| --- | --- |
| `src/fruit_market/` | the sim: `sim_types`, `board`, `sim_config`, `sim_state`, `events`, `market`, `kernel`, `sim`, `scripted`, `llm`, `replays`, `broadcast`, `global`, `server`, `wire_constants` |
| `src/fruit_market.nim` | the game entrypoint (`/bin/fruit-market`) |
| `src/fruit_market_player.nim` | the seat process (`/bin/fruit-market-player`) |
| `client/` | the broadcast chrome: `chrome_common.js` byte-for-byte from `coworld-ctf`, `broadcast_core.js` forked, `replay_broadcast.html` = the starter's page with the game block appended |
| `replay-viewer/` | the static wasm bundle: `fruit_market_replay.nim`, `config.nims`, `static_replay.js`, `static_replay_worker.js` |
| `scripts/art/` | the nano-banana source renders and the split script that produces every file in `data/` |
| `tests/` | nine suites: map, sim, market, baseline, feasibility, replay, llm, manifest, broadcast |
| `tools/ci/` | the CI harness: docker smoke, viewer smoke, DOM text smoke, renderer fixture, manifest loader |

## Building and running

The sandbox has no Docker, no Nim and no emsdk; CI is the harness.

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r -d:release --path:src tests/test_sim.nim     # any suite
docker build --platform=linux/amd64 -t coworld-fruit-market:ci .
tools/ci/docker_smoke.sh coworld-fruit-market:ci   # one real 8-seat episode
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

Replays are a **static file plus a browser wasm viewer**, never a pod:
`index.html?replay=<url>` decodes the recorded state frames in the browser and
contacts no server but S3.

## The economy, and how it is enforced

`tests/test_feasibility.nim` is the oracle, run over seeds 1..12 on all four
variants, and it is a CI precondition rather than a report:

* **(a) the baselines make a market** — all-`hauler` rooms finish, at least 24
  trades execute, every seat scores at least 60, nobody spends 120 ticks
  starving;
* **(b) trade beats autarky** — haulers out-score homesteaders by at least 1.5×;
* **(c) geography bites** — deep rivers cost the recluse more than the trader;
* **(d) reading the book is viable** — a kernel that mirrors the biggest offer
  it can see never does worse than the book price.

Any constant change re-runs the oracle. That is what stops a retune shipping a
dead market.

## License

MIT. See `LICENSE`.
