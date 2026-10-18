#!/usr/bin/env python3
"""Распаковка pkg и проверка одного настоящего runtime в изолированном профиле."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


class Client:
    """Независимый JSON-RPC клиент с ограниченным ожиданием ответа."""

    def __init__(self, command: str) -> None:
        self.process = subprocess.Popen(
            [command],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.messages: queue.Queue[Any] = queue.Queue()
        self.counter = 0
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self) -> None:
        assert self.process.stdout is not None
        try:
            while line := self.process.stdout.readline(1_048_578):
                if len(line) > 1_048_576:
                    raise RuntimeError("Oversized frame")
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.counter += 1
        assert self.process.stdin is not None
        self.process.stdin.write(
            (
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": self.counter,
                        "method": method,
                        "params": params,
                    }
                )
                + "\n"
            ).encode()
        )
        self.process.stdin.flush()
        while True:
            reply = self.messages.get(timeout=20)
            if isinstance(reply, Exception):
                raise reply
            if reply.get("id") == self.counter:
                return reply

    def call(self, tool: str) -> dict[str, Any]:
        return self.request("tools/call", {"name": tool, "arguments": {}})

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        if self.process.stdout:
            self.process.stdout.close()
        self.reader.join(timeout=1)


def main() -> None:
    """Никакой установки от root, изменения клиентских профилей или выдачи grants."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args()
    if not args.run:
        parser.error("--run required for own temporary launchd job")
    metadata = json.loads((ROOT / "snapshot.json").read_text())
    domain = metadata["domain"]
    report: dict[str, Any] = {
        "domain": domain,
        "checks": [],
        "systemInstallationPerformed": False,
        "globalClientRegistrationChanged": False,
        "userDataGrantsIssued": False,
        "profileIsStrictNonTest": True,
        "guiLaunched": False,
    }
    installer = ROOT / (metadata["name"] + "-E10-arm64-local.pkg")
    with tempfile.TemporaryDirectory(
        prefix="ecosystem-e3b-desktop-" + domain + "-", dir="/private/tmp"
    ) as temporary:
        base = Path(temporary)
        expanded = base / "expanded"
        subprocess.run(
            [
                "/usr/sbin/pkgutil",
                "--expand-full",
                str(installer),
                str(expanded),
            ],
            check=True,
            capture_output=True,
        )
        apps = list(expanded.rglob(metadata["appName"] + ".app"))
        assert len(apps) == 1
        app = apps[0]
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            check=True,
            capture_output=True,
        )
        report["checks"].append("pkg-expanded-complete-app-signature-valid")
        resources = app / "Contents/Resources"
        spec = importlib.util.spec_from_file_location(
            "snapshot_local", resources / "local_runtime.py"
        )
        assert spec and spec.loader
        local = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(local)
        assert set(local.PRODUCTS) == {domain}
        profile = base / "profile"
        entry = resources / "snapshot_entry.py"

        def operation(action: str) -> dict[str, Any]:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(entry),
                    action,
                    "--app",
                    str(app),
                    "--profile",
                    str(profile),
                ],
                capture_output=True,
                check=True,
                text=True,
                timeout=45,
            )
            return json.loads(completed.stdout)

        try:
            operation("start")
            value = local.manifest(profile)
            assert (
                set(value["agents"]) == {domain}
                and value["testProfile"] is False
            )
            assert all(
                " or " not in endpoint["clientRequirement"]
                for endpoint in json.loads(
                    (profile / (domain + ".json")).read_text()
                )["endpoints"].values()
            )
            assert operation("status")[domain]["running"] is True
            report["checks"].append(
                "single-domain-runtime-strict-CDHash-profile-ready"
            )
            for principal in ["codex", "deepseekHarness"]:
                client = Client(
                    value["agents"][domain]["clients"][principal]["wrapper"]
                )
                try:
                    response = client.request(
                        "initialize",
                        {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {
                                "name": "snapshot-check",
                                "version": "1",
                            },
                        },
                    )
                    assert "result" in response
                    assert client.process.stdin is not None
                    client.process.stdin.write(
                        b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
                    )
                    client.process.stdin.flush()
                    tools = client.request("tools/list", {})["result"]["tools"]
                    assert len(tools) == (32 if domain == "ares" else 30)
                    status = client.call("agent.get_status")["result"]
                    assert not status.get("isError")
                    data = json.loads(status["content"][0]["text"])
                    assert (
                        data["agentId"] == domain
                        and data["runtimeIntegrated"] is True
                    )
                    denied = client.call(
                        "file.list_roots"
                        if domain == "ares"
                        else "system.get_metrics"
                    )
                    assert denied["result"][
                        "isError"
                    ] is True and "PERMISSION_DENIED" in json.dumps(denied)
                    report["checks"].append(
                        principal + "-real-MCP-status-catalog-and-default-deny"
                    )
                finally:
                    client.close()
            # Повторный запуск использует тот же профиль. Stop/start сохраняет
            # идентификатор и состояние, но обновляет снимок кода штатным путём.
            operation("start")
            assert local.manifest(profile)["identifier"] == value["identifier"]
            operation("stop")
            operation("start")
            assert local.manifest(profile)["identifier"] == value["identifier"]
            report["checks"].append(
                "repeat-and-restart-preserve-own-profile-identity"
            )
        finally:
            if (profile / "profile.json").exists():
                assert all(local.stop(profile).values())
                report["temporaryJobRemoved"] = True
        assert not list(app.rglob("__pycache__"))
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            check=True,
            capture_output=True,
        )
        report["checks"].append("launcher-does-not-modify-signed-bundle")
    report["status"] = "passed"
    (ROOT / "verification.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                "status": "passed",
                "domain": domain,
                "checks": len(report["checks"]),
            }
        )
    )


if __name__ == "__main__":
    main()
