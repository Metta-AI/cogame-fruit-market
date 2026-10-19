"""Complete published Fruit Market games with matched prompt wordings."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
VARIANTS = ("open-market", "concentric-rivers", "deep-rivers", "lean-harvest")
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording="canonical", prompt_seed=0, numeric=False, text=False):
    command = [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant]
    if not numeric:
        command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "seed": str(seed),
                "players": 8,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems = [], {}
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace) and seat == index % 8
            view = observation["semantic_view"].copy()
            messages = observation["messages"]
            assert (
                systems.setdefault(seat, messages[0]["content"])
                == messages[0]["content"]
            )
            if not numeric:
                metadata = view.pop("prompt_template")
                assert (
                    metadata["bank"],
                    metadata["variant"],
                    metadata["selection"],
                    metadata["seed"],
                ) == (
                    "fruit-market-rules-v2",
                    WORDINGS[prompt_seed % 5] if wording == "mixed" else wording,
                    wording,
                    prompt_seed,
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            action = json.loads(request({"kind": "teacher"})["response"])
            if text:
                action["say"] = f"SPECTATOR-SEAT-{seat}"
                action["notes"] = f"PRIVATE-SEAT-{seat}"
                for other in range(8):
                    assert f"SPECTATOR-SEAT-{other}" not in messages[1]["content"]
                    if other != seat:
                        assert f"PRIVATE-SEAT-{other}" not in messages[1]["content"]
            expected = json.loads(json.dumps(action))
            if text and index == 0:
                action["job"] = "  " + action["job"].upper() + "  "
                action["offer"]["give"]["n"] = "100"
                action["offer"]["want"]["n"] = "-3"
                expected["offer"]["give"]["n"] = 6
                expected["offer"]["want"]["n"] = 1
            trace.append((view, messages[1]["content"], action))
            result = request(
                {"kind": "step", "decision_id": index, "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == expected
            observation = result["observation"]
        assert len(trace) == 96 and len(observation["scores"]) == 8
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, systems


for variant in VARIANTS:
    canonical = play(variant, 17)
    systems = []
    for wording, seed in [(wording, 0) for wording in WORDINGS] + [("mixed", 4)]:
        candidate = play(variant, 17, wording, seed)
        assert candidate[:2] == canonical[:2]
        if wording != "mixed":
            systems.append(candidate[2])
    assert all(len({system[seat] for system in systems}) == 7 for seat in range(8))
    play(variant, 17, text=True)
    print(variant, "10 complete matched/normalization games PASS", flush=True)
for wording in WORDINGS[-2:]:
    result = subprocess.run(
        [
            str(BRIDGE),
            str(ROOT / "coworld_manifest_template.json"),
            VARIANTS[0],
            "text",
        ],
        input=json.dumps(
            {
                "kind": "reset",
                "seed": "17",
                "players": 8,
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        result.returncode != 0
        and "held-out wording cannot be used for training" in result.stderr
    )
print("40 complete language games; held-out gate PASS", flush=True)
