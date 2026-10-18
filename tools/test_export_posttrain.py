"""Export complete Fruit Market games and verify installed orders and tick evidence."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="fruit-market-source-export-"))
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
VARIANTS = ("open-market", "concentric-rivers", "deep-rivers", "lean-harvest")
VOCABULARY = {"wait", "move_n", "move_s", "move_e", "move_w", "harvest"}
for variant in VARIANTS:
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert not (output / "train.jsonl").exists() and not (output / "validation.jsonl").exists()
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    for line in (output / "trajectories.jsonl").read_text().splitlines():
        row = json.loads(line)
        assert row["source_revision"] == revision
        episode = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[episode] = row
            continue
        decisions.setdefault(episode, []).append(row)
        assert row["visibility"] == "private" and row["action_status"] == "accepted"
        (attempt,) = row["attempts"]
        assert attempt["origin"] == "teacher" and attempt["request"] is None
        assert attempt["platform_call_id"] is None and attempt["behavior_logprobs"] is None
        assert row["selected_attempt_id"] == attempt["attempt_id"] and attempt["accepted"]
        assert row["executed_action"] == attempt["parsed_action"] == json.loads(attempt["response"])
        view = row["observation"]
        assert all("notes" not in other for other in view["view"]["cogs"])
        metadata = view["prompt_template"]
        assert metadata["bank"] == "fruit-market-rules-v1" and metadata["variant"] == "canonical"
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower() == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    with (output / "execution.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            executions.setdefault(row["episode_id"], []).append(row)
            assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, shifts = decisions[episode], executions[episode]
        assert outcome["status"] == "completed" and outcome["outcome"]["reason"] == "complete"
        assert outcome["outcome"]["rounds"] == 12 and outcome["outcome"]["ending"] == "round_limit"
        assert len(rows) == 96 and len(shifts) == 12
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        for index, shift in enumerate(shifts):
            batch = rows[index * 8 : (index + 1) * 8]
            assert shift["decision_ids"] == [row["decision_id"] for row in batch]
            assert shift["start_tick"] == index * 60 and shift["end_tick"] == (index + 1) * 60
            assert [frame["t"] for frame in shift["frames"]] == list(range(index * 60, (index + 1) * 60))
            assert len(shift["kernel_actions"]) == 60
            assert all(len(actions) == 8 and set(actions) <= VOCABULARY for actions in shift["kernel_actions"])
            assert shift["terminal"] == (index == 11)
            assert shift["event_end"] - shift["event_start"] == len(shift["events"])
            if index:
                assert shift["event_start"] == shifts[index - 1]["event_end"]
            orders = [event for event in shift["events"] if event["k"] == "order"]
            assert len(orders) == 8
            for seat, (row, order) in enumerate(zip(batch, orders, strict=True)):
                assert row["seat"] == str(seat) and order["seat"] == seat
                action = row["executed_action"]
                assert all(action[key] == order[key] for key in ("job", "eat", "say", "notes"))
                assert action["offer"] == {
                    "give": {"fruit": order["offer"]["give"], "n": order["offer"]["giveN"]},
                    "want": {"fruit": order["offer"]["want"], "n": order["offer"]["wantN"]},
                }
                if "stall" in action:
                    assert action["stall"] == order["stall"]
                assert order["source"] == "scripted"
                view = row["observation"]
                assert view["round"] == index + 1 and view["tick"] == index * 60
                assert all("farmType" not in other and "notes" not in other for other in view["view"]["cogs"])
        for seat in range(8):
            assert outcome["participant_outcomes"][str(seat)]["score"] == outcome["outcome"]["scores"][seat]
    assert {row["seed_family"] for row in episodes.values()} == {f"fruit-market-{seed}" for seed in range(1, 11)}
    print(
        variant,
        "10 complete exports; frozen observations, hashes, installed orders and tick evidence PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
