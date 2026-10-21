#!/usr/bin/env python3
"""Настоящий crash/restart на синтетических файлах в собственной временной папке."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import selectors
import subprocess
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parent.parent


def execute(
    binary: Path,
    directory: Path,
    mode: str,
    extra: list[str] | None = None,
    domain: str = "ares",
) -> subprocess.CompletedProcess[str]:
    """Только диагностический executable; shell/user profiles не используются."""
    return subprocess.run(
        [
            str(binary),
            "--domain",
            domain,
            "--directory",
            str(directory),
            "--mode",
            mode,
        ]
        + (extra or []),
        text=True,
        capture_output=True,
        timeout=15,
    )


def require(condition: bool, message: str) -> None:
    """Не используем assert: python -O не должен отключать проверку результата."""
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    """Проверяет crash points и записывает отчёт после удаления fixtures."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.run:
        parser.error("--run is required for intentional child-process crashes")
    binary = (ROOT / ".build/debug/EcosystemQueueProbe").resolve(strict=True)
    checks: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(
        prefix="ecosystem-e3-", dir="/private/tmp"
    ) as temporary:
        base = Path(temporary)
        owner = subprocess.Popen(
            [
                str(binary),
                "--domain",
                "ares",
                "--directory",
                str(base / "owner"),
                "--mode",
                "hold",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            require(owner.stdout is not None, "Missing owner stdout")
            with selectors.DefaultSelector() as selector:
                selector.register(owner.stdout, selectors.EVENT_READ)
                require(
                    bool(selector.select(timeout=10)), "Owner startup timeout"
                )
            require(
                json.loads(owner.stdout.readline())["ready"] is True,
                "Owner not ready",
            )
            require(
                execute(binary, base / "owner", "inspect").returncode == 73,
                "Second owner accepted",
            )
            require(
                execute(
                    binary, base / "athena", "run", domain="athena"
                ).returncode
                == 0,
                "Independent Athena blocked",
            )
            checks.append(
                {
                    "check": "exclusive-owner-and-independent-domain",
                    "passed": True,
                }
            )
        finally:
            owner.terminate()
            owner.communicate(timeout=10)
        require(
            execute(binary, base / "owner", "inspect").returncode == 0,
            "Kernel lock not released",
        )
        checks.append(
            {"check": "owner-lock-released-after-process-exit", "passed": True}
        )
        points = [
            "beforeAdmissionCommit",
            "afterAdmissionCommit",
            "after-claim",
            "beforeReceiptCommit",
            "afterReceiptCommit",
            "after-effect",
            "after-done",
            "beforeResultCommit",
            "afterResultCommit",
        ]
        for point in points:
            directory = base / point
            crashed = execute(
                binary,
                directory,
                "run",
                [
                    "--mutating",
                    "yes",
                    "--allow-test-effects",
                    "yes",
                    "--crash",
                    point,
                ],
            )
            require(crashed.returncode == 70, "Expected crash at " + point)
            inspected = execute(binary, directory, "inspect")
            require(inspected.returncode == 0, "Restart failed at " + point)
            state = json.loads(inspected.stdout)
            tasks = state["tasks"]
            if point == "beforeAdmissionCommit":
                require(not tasks, "Uncommitted admission survived")
            else:
                expected = (
                    "queued"
                    if point == "afterAdmissionCommit"
                    else (
                        "interrupted"
                        if point in ["after-claim", "beforeReceiptCommit"]
                        else (
                            "completed"
                            if point == "afterResultCommit"
                            else "recoveryRequired"
                        )
                    )
                )
                require(
                    len(tasks) == 1 and tasks[0]["status"] == expected,
                    "Unsafe recovery at " + point,
                )
                require(
                    tasks[0]["resultStored"] == (point == "afterResultCommit"),
                    "False result publication",
                )
            has_effect = point in [
                "after-effect",
                "after-done",
                "beforeResultCommit",
                "afterResultCommit",
            ]
            require(
                state["effectExists"] == has_effect,
                "Wrong synthetic effect at " + point,
            )
            if point in [
                "afterReceiptCommit",
                "after-effect",
                "after-done",
                "beforeResultCommit",
            ]:
                require(
                    execute(
                        binary, directory, "admit", ["--key", "different"]
                    ).returncode
                    == 74,
                    "Uncertain resource was reused",
                )
                repeat = execute(
                    binary,
                    directory,
                    "run",
                    ["--mutating", "yes", "--allow-test-effects", "yes"],
                )
                require(
                    repeat.returncode == 0
                    and json.loads(repeat.stdout)["status"]
                    == "recoveryRequired",
                    "Unsafe blind replay",
                )
            checks.append({"check": point, "passed": True})
    report = {
        "stage": "E3-queue-core",
        "checks": checks,
        "checksPassed": len(checks),
        "syntheticFixturesRemoved": True,
        "userDatabasesTouched": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            {"checksPassed": len(checks), "syntheticFixturesRemoved": True}
        )
    )


if __name__ == "__main__":
    main()
