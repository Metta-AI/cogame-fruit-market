"""Check external Fruit Market orders beside seven scripted seats in Docker."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class SystemOne(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(body["state"].split("observation:\n", 1)[1])
        selected = "harvest" if observation["round"] == 1 else "market_north"
        choices = body["questions"]["decision"]["criteria"]
        assert selected in choices
        self.calls.append((dict(self.headers), body["model"], observation))
        payload = json.dumps(
            {
                "model": body["model"],
                "answers": {
                    "decision": {
                        "type": "choice",
                        "confidence": 1.0,
                        "probabilities": {
                            choice: float(choice == selected) for choice in choices
                        },
                    }
                },
                "usage": {"input_tokens": 100, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True, timeout=90
    ).stdout.strip()


if __name__ == "__main__":
    image = sys.argv[1]
    server = http.server.HTTPServer(("0.0.0.0", 0), SystemOne)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    name = f"fruit-jev-{os.getpid()}"
    network = f"{name}-net"
    containers = [f"{name}-game", *(f"{name}-p{slot}" for slot in range(8))]
    with tempfile.TemporaryDirectory(prefix="fruit-jev-smoke-") as directory:
        work = Path(directory)
        os.chmod(work, 0o777)
        (work / "config.json").write_text(
            json.dumps(
                {
                    "seed": 7,
                    "num_agents": 8,
                    "rounds": 2,
                    "ticksPerRound": 20,
                    "minTurnSeconds": 0,
                    "llmTimeoutSeconds": 3,
                    "playerConnectTimeoutSeconds": 10,
                    "shutdownGraceSeconds": 0,
                    "episodeTimeoutSeconds": 120,
                    "tokens": [f"token-{slot}" for slot in range(8)],
                    "players": [{"name": f"player-{slot}"} for slot in range(8)],
                }
            )
        )
        docker("network", "create", network)
        passed = False
        try:
            docker(
                "run", "-d", "--name", containers[0], "--network", network,
                "--network-alias", "fruit-game", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                "-v", f"{work}:/coworld:rw", image, "/bin/fruit-market",
            )
            time.sleep(1)
            for slot in range(8):
                args = [
                    "run", "-d", "--name", containers[slot + 1],
                    "--network", network,
                    "--add-host", "host.docker.internal:host-gateway",
                    "-e", f"COWORLD_PLAYER_WS_URL=ws://fruit-game:8080/"
                    f"player?slot={slot}&token=token-{slot}",
                ]
                if slot == 0:
                    args += [
                        "-e", "PLAYER_JEV=1", "-e",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME="
                        f"http://host.docker.internal:{server.server_port}",
                    ]
                else:
                    args += ["-e", "PLAYER_SCRIPTED=hauler"]
                docker(*args, image, "/bin/fruit-market-player")
            assert docker("wait", containers[0]) == "0"
            for container in containers[1:]:
                assert docker("wait", container) == "0"
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            orders = [row for row in replay["events"] if row["k"] == "order"]
            jev_orders = [row for row in orders if row["seat"] == 0]
            assert results["reason"] == "complete"
            assert results["rounds"] == 2
            assert len(SystemOne.calls) == len(jev_orders) == 2
            assert [(row["job"], row["source"]) for row in jev_orders] == [
                ("harvest", "external"), ("market", "external")
            ]
            assert jev_orders[1]["stall"] == "north"
            assert jev_orders[1]["offer"] is not None
            assert all(row["source"] == "scripted" for row in orders if row["seat"] > 0)
            for headers, model, observation in SystemOne.calls:
                assert headers["x-coworld-player-slot"] == "0"
                assert "authorization" not in headers
                assert model == "typesafe/jev-1.13"
                assert observation["slot"] == 0
                assert all("farmType" not in cog for cog in observation["view"]["cogs"])
            print("Fruit Market: 2 accepted Jev orders, 7 scripted seats, complete replay")
            passed = True
        finally:
            if not passed:
                for container in containers:
                    logs = subprocess.run(
                        ["docker", "logs", container], capture_output=True, text=True
                    )
                    print(logs.stdout, logs.stderr, file=sys.stderr)
            for container in containers:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)
            server.shutdown()
            thread.join()
