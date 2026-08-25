#!/usr/bin/env python3
"""Load coworld_manifest_template.json with the installed coworld package's own
`_load_template_manifest`.

Phase 40's `coworld build` rejects a template repo CI happily parsed
(collab-cooking, 2026-08-25): 0.1.42 wants `game.replay_viewer` rather than a
top-level one, no top-level `version`, no `game.display_name`, `game.owner`
present, and NO runner-managed `tokens` in the certification fixture. Running
the real loader here fails in repo CI instead of two phases later.

Usage: python3 tools/ci/check_manifest_loads.py [manifest]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MANIFEST = Path(sys.argv[1] if len(sys.argv) > 1 else "coworld_manifest_template.json")


def load_with_coworld(path: Path) -> None:
    """Run the CLI's OWN template loader and its OWN upload validator."""
    from coworld import bundle as coworld_bundle  # type: ignore
    from coworld.manifest import validate_upload_manifest  # type: ignore

    loader = getattr(coworld_bundle, "_load_template_manifest", None)
    if loader is None:
        raise SystemExit(
            "the installed coworld package has no _load_template_manifest; "
            "pin the version this check was written against"
        )
    document = json.loads(path.read_text())
    placeholders = {
        placeholder: f"{placeholder.strip('{}').lower()}:0.0.0"
        for placeholder in _placeholders(document)
    }
    manifest = loader(document, "0.0.0", placeholders)
    print(f"coworld loaded {path}: {type(manifest).__name__}")
    validated = validate_upload_manifest(
        manifest.model_dump(mode="json", exclude_none=True)
    )
    print(f"coworld validated the upload document: {type(validated).__name__}")


def _placeholders(node) -> set[str]:
    """Every {{X_IMAGE}} the template references, whatever nests it."""
    found: set[str] = set()
    if isinstance(node, dict):
        for value in node.values():
            found |= _placeholders(value)
    elif isinstance(node, list):
        for value in node:
            found |= _placeholders(value)
    elif isinstance(node, str) and node.startswith("{{") and node.endswith("}}"):
        found.add(node)
    return found


def local_invariants(path: Path) -> None:
    """The invariants that do not need the CLI, asserted either way."""
    data = json.loads(path.read_text())
    game = data.get("game") or {}
    cert = data.get("certification") or {}
    problems = []
    if "version" in data:
        problems.append("top-level `version` is rejected by coworld 0.1.42")
    if "replay_viewer" in data:
        problems.append("`replay_viewer` must live under `game`, not top level")
    if "display_name" in game:
        problems.append("`game.display_name` is rejected by coworld 0.1.42")
    if not game.get("owner"):
        problems.append("`game.owner` is required")
    if (game.get("replay_viewer") or {}).get("bundle") != "static-replay-viewer":
        problems.append('`game.replay_viewer.bundle` must be "static-replay-viewer"')
    if "episode_timeout_minutes" not in data:
        problems.append("`episode_timeout_minutes` must be top level")
    if len(data.get("tags") or []) < 3:
        problems.append("at least three `tags` are required")
    if "tokens" in (cert.get("game_config") or {}):
        problems.append(
            "certification.game_config must NOT declare runner-managed `tokens`"
        )
    if (game.get("runnable") or {}).get("type") != "game":
        problems.append('`game.runnable.type` must be "game"')
    seats = (cert.get("game_config") or {}).get("num_agents")
    if not isinstance(seats, int) or seats < 1:
        problems.append("certification.game_config.num_agents must be a positive int")
    for variant in data.get("variants") or []:
        if not variant.get("description"):
            problems.append(f"variant {variant.get('id')} has no description")
        if (variant.get("game_config") or {}).get("num_agents") != seats:
            problems.append(
                f"variant {variant.get('id')} num_agents disagrees with the fixture"
            )
    declared = {entry.get("id") for entry in (data.get("player") or [])}
    seated = {row.get("player_id") for row in (cert.get("players") or [])}
    missing = declared - seated
    if missing:
        problems.append(f"player entries never seated in certification: {sorted(missing)}")
    props = ((game.get("config_schema") or {}).get("properties") or {})
    for name, spec in props.items():
        if spec.get("type") == "array" and not (
            "minItems" in spec and "maxItems" in spec
        ):
            problems.append(f"config_schema.{name} is an array without minItems/maxItems")
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        raise SystemExit(1)
    print(f"local manifest invariants OK ({len(props)} config properties)")


def main() -> None:
    if not MANIFEST.exists():
        raise SystemExit(f"manifest not found: {MANIFEST}")
    local_invariants(MANIFEST)
    try:
        load_with_coworld(MANIFEST)
    except ImportError:
        raise SystemExit(
            "the coworld package is not importable; install it with "
            '`uvx --from "coworld[auth]==0.1.42"` or pip before running this check'
        )


if __name__ == "__main__":
    main()
