"""Complete mixed-wording exports retain simultaneous orders and seed families."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
VARIANTS = ("open-market", "concentric-rivers", "deep-rivers", "lean-harvest")
with tempfile.TemporaryDirectory() as directory:
    for variant in VARIANTS:
        output = Path(directory) / variant
        subprocess.run(
            [str(EXPORTER), str(output), "10", "1", variant, "mixed", "0"],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((output / "manifest.json").read_text())
        assert [run["prompt_selection"]["variant"] for run in manifest["runs"]] == [
            "canonical",
            "plain",
            "numbered",
            "questions",
            "reordered",
        ] * 2
        counts, families = {}, {}
        for split in ("train", "validation"):
            rows = [
                json.loads(line)
                for line in (output / (split + ".jsonl")).read_text().splitlines()
            ]
            assert len(rows) == manifest[split + "_examples"] > 0
            families[split] = {row["seed"] for row in rows}
            for row in rows:
                counts[row["seed"]] = counts.get(row["seed"], 0) + 1
                assert row["prompt_template"]["bank"] == "fruit-market-rules-v2"
                for message in row["prompt"]:
                    assert (
                        row["prompt_template"][message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                action = json.loads(row["completion"][0]["content"])
                assert action["job"] in ("harvest", "market", "trek", "rest")
                assert set(action["offer"]) == {"give", "want"}
                assert (
                    1 <= action["offer"]["give"]["n"] <= 6
                    and 1 <= action["offer"]["want"]["n"] <= 6
                )
        assert families["train"].isdisjoint(families["validation"])
        assert all(
            counts[f"fruit-market-{run['seed']}"]
            == run["decisions"]
            == run["rounds"] * 8
            for run in manifest["runs"]
        )
        print(variant, "10 complete mixed export games PASS", flush=True)
