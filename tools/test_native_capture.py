"""Complete native games against a loopback-only Messages fixture, never a teacher."""

import argparse
import base64
import json
import os
import socket
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--mode",
        choices=("accepted", "invalid", "429", "normalized"),
        default="accepted",
    )
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--no-capture", action="store_true")
    parser.add_argument(
        "--source-revision", default="loopback-working-tree-not-a-published-source"
    )
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    calls = []
    lock = threading.Lock()
    canary = "PRIVATE_OPERATOR_LOOPBACK_FIXTURE"

    class Fixture(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.path == "/v1/messages"
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            request = json.loads(raw)
            assert canary in request["messages"][0]["content"]
            with lock:
                call_id = f"00000000-0000-4000-8000-{len(calls) + 1:012d}"
                order = {
                    "job": "harvest",
                    "eat": "any",
                    "say": "fixture",
                    "notes": "local",
                }
                if args.mode == "invalid":
                    order["job"] = "not-a-native-job"
                elif args.mode == "normalized":
                    order["notes"] = "local\rnormalized"
                body = json.dumps(
                    {
                        "model": "loopback-fixture",
                        "stop_reason": "end_turn",
                        "content": [{"type": "text", "text": json.dumps(order)}],
                    }
                ).encode()
                status = 429 if args.mode == "429" else 200
                if status == 429:
                    body = b'{"error":{"type":"rate_limit_error","message":"local fixture"}}'
                calls.append(
                    {
                        "id": call_id,
                        "slot": self.headers["X-Coworld-Player-Slot"],
                        "request": request,
                        "request_raw": raw.decode(),
                        "response_raw": body.decode(),
                        "status": status,
                    }
                )
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            pass

    fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        port = available.getsockname()[1]
    config = {
        "seed": args.seed,
        "num_agents": 8,
        "tokens": [f"token-{s}" for s in range(8)],
        "players": [{"name": f"fixture-{s}"} for s in range(8)],
        "rounds": 12,
        "minTurnSeconds": 0,
        "playerConnectTimeoutSeconds": 10,
        "shutdownGraceSeconds": 0,
    }
    (output / "config.json").write_text(json.dumps(config))
    # Construct a clean environment: credentials and inherited remote endpoints never reach fixtures.
    env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR") if k in os.environ}
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(output / "config.json").as_uri(),
        COGAME_RESULTS_URI=(output / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(output / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(output / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID="fixture-only-not-a-hosted-episode",
        COWORLD_GAME_VERSION="fixture-only",
        COWORLD_SOURCE_REVISION=args.source_revision,
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{fixture.server_port}",
        COWORLD_LLM_MODEL="loopback-fixture",
    )
    if args.no_capture:
        del env["COGAME_SAVE_TRAJECTORY_URI"]
    processes, logs = [], []
    try:
        game_log = (output / "game.log").open("w")
        logs.append(game_log)
        game = subprocess.Popen(
            [str(args.game.resolve())],
            env=env,
            stdout=game_log,
            stderr=subprocess.STDOUT,
        )
        processes.append(game)
        deadline = time.monotonic() + 60
        while True:
            assert game.poll() is None, "Game exited before health probe"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ):
                    break
            except OSError:
                assert time.monotonic() < deadline, "Game never became healthy"
                time.sleep(0.05)
        for seat in range(8):
            player_env = {
                k: v for k, v in env.items() if k in ("PATH", "HOME", "TMPDIR")
            }
            player_env["COWORLD_PLAYER_WS_URL"] = (
                f"ws://127.0.0.1:{port}/player?slot={seat}&token=token-{seat}"
            )
            if seat < 2:
                player_env["PLAYER_PROMPT"] = canary
            else:
                player_env["PLAYER_SCRIPTED"] = "hauler"
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen(
                    [str(args.player.resolve())],
                    env=player_env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            )
        assert game.wait(timeout=60) == 0
        for process in processes[1:]:
            assert process.wait(timeout=5) == 0
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        for log in logs:
            log.close()
        fixture.shutdown()
        fixture.server_close()
        (output / "fixture-calls.json").write_text(json.dumps(calls, indent=2) + "\n")
    results = json.loads((output / "results.json").read_text())
    assert results["reason"] == "complete" and results["rounds"] == 12, results
    assert canary not in (output / "replay.json").read_text()
    trajectory = output / "trajectory.jsonl"
    if args.no_capture:
        assert not trajectory.exists()
        print(
            json.dumps(
                {
                    "fixture_only": True,
                    "capture_disabled": True,
                    "fixture_calls": len(calls),
                }
            )
        )
        return
    assert trajectory.is_file(), (
        "Complete native game did not retain its private trajectory"
    )
    events = [json.loads(line) for line in trajectory.read_text().splitlines()]
    assert events[-1]["event_type"] == "episode" and events[-1]["status"] == "completed"
    decisions = events[:-1]
    assert len(decisions) == 96
    actual = [a for d in decisions for a in d["attempts"] if a["origin"] == "model"]
    assert (
        len(actual)
        == len(calls)
        == (24 if args.mode in ("accepted", "normalized") else 48)
    )
    received = {c["id"]: c for c in calls}
    for attempt in actual:
        call = received[attempt["platform_call_id"]]
        assert attempt["request"] == call["request"]
        assert (
            base64.b64decode(attempt["response_body_b64"]).decode()
            == call["response_raw"]
        )
        assert attempt["http_status"] == call["status"]
    for decision in decisions:
        if int(decision["seat"]) < 2 and args.mode == "normalized":
            assert decision["action_status"] == "rejected"
            assert decision["selected_attempt_id"] is None
            assert (
                decision["attempts"][0]["parsed_action"]["notes"] == "local\rnormalized"
            )
            assert decision["executed_action"]["notes"] == "local normalized"
            assert not decision["attempts"][0]["accepted"]
            continue
        selected = next(
            a
            for a in decision["attempts"]
            if a["attempt_id"] == decision["selected_attempt_id"]
        )
        assert (
            selected["accepted"]
            and selected["parsed_action"] == decision["executed_action"]
        )
        origin = (
            "teacher"
            if int(decision["seat"]) >= 2
            else "model"
            if args.mode == "accepted"
            else "fallback"
        )
        assert selected["origin"] == origin
    print(
        json.dumps(
            {
                "mode": args.mode,
                "rounds": 12,
                "fixture_calls": len(calls),
                "decisions": len(decisions),
                "family": events[-1]["seed_family"],
                "fixture_only": True,
            }
        )
    )


if __name__ == "__main__":
    main()
