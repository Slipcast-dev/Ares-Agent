#!/usr/bin/env python3
"""Первый запуск одного агента: частный профиль и только его launchd job."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import local_runtime as local


def main() -> int:
    """Профиль создаётся после запуска пользователем, а не от root в installer."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        nargs="?",
        default="launch",
        choices=["launch", "start", "gui", "stop", "status"],
    )
    parser.add_argument(
        "--app", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument("--profile", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        app = args.app.resolve(strict=True)
        metadata = json.loads(
            (app / "Contents/Resources/snapshot.json").read_text()
        )
        domain = metadata["domain"]
        if set(local.PRODUCTS) != {domain}:
            raise RuntimeError("Domain mismatch")
        profile = (
            args.profile
            or Path.home()
            / "Library/Application Support/SubAgent Intermediates"
            / metadata["name"]
        )
        if not profile.is_absolute():
            raise RuntimeError("Absolute profile required")
        local.SOURCE_APP = app
        if args.action == "stop":
            print(json.dumps({"stopped": local.stop(profile)}))
            return 0
        if args.action == "status":
            if not (profile / "profile.json").exists():
                print(json.dumps({"state": "not-created", "domain": domain}))
            else:
                print(json.dumps(local.persistence_status(profile, None)))
            return 0
        # Чужие jobs не затрагиваются; обновление работающего профиля не
        # прерывает принятую задачу без явной остановки пользователем.
        digest = hashlib.sha256()
        for name in [
            metadata["native"],
            metadata["mcp"],
            metadata["runtime"],
        ] + ([metadata["worker"]] if metadata["worker"] else []):
            digest.update((app / "Contents/MacOS" / name).read_bytes())
        fingerprint = digest.hexdigest()
        if (profile / "profile.json").exists():
            saved = local.manifest(profile)
            if saved.get("sourceBuildDigest") != fingerprint and any(
                local.job_running(item["label"])
                for item in saved["agents"].values()
            ):
                print(
                    "Остановите этот профиль перед обновлением сборки.",
                    file=sys.stderr,
                )
                return 2
        value = local.start(profile)
        with local.persistence_lock(profile):
            saved = local.manifest(profile)
            saved["sourceBuildDigest"] = fingerprint
            local.write_private(
                profile / "profile.json", json.dumps(saved, indent=2).encode()
            )
        if args.action in {"launch", "gui"}:
            local.open_guis(profile)
        print(
            json.dumps(
                {
                    "domain": domain,
                    "running": True,
                    "guiRequested": args.action != "start",
                }
            )
        )
        return 0
    except Exception as error:
        # В stdout/stderr никогда не копируем JSON конфигурации и данные агента.
        print(
            "Не удалось запустить локальный профиль: " + type(error).__name__,
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
