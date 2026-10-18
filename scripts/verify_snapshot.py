#!/usr/bin/env python3
"""Проверка независимой vendored зависимости без исходного репозитория."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import os

ROOT = Path(__file__).resolve().parents[1]


def inventory() -> dict[str, str]:
    """Генерируем только исходники пакета, никогда .build или личное состояние."""
    result: dict[str, str] = {}
    package = ROOT / "Packages/EcosystemKit"
    for directory, folders, files in os.walk(package):
        folders[:] = [
            p
            for p in folders
            if p not in {".build", ".swiftpm", "__pycache__", ".artifacts"}
        ]
        for name in files:
            path = Path(directory) / name
            if name == ".DS_Store" or path.suffix == ".pyc":
                continue
            if path.is_symlink():
                raise RuntimeError("Symlink in shared package")
            result[path.relative_to(package).as_posix()] = hashlib.sha256(
                path.read_bytes()
            ).hexdigest()
    return dict(sorted(result.items()))


def main() -> None:
    """Refresh — явное действие разработчика после проверки diff, не часть build."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    path = ROOT / "snapshot.json"
    snapshot = json.loads(path.read_text())
    actual = inventory()
    if args.refresh:
        snapshot["sharedFiles"] = actual
        path.write_text(
            json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n"
        )
    if actual != snapshot.get("sharedFiles"):
        raise RuntimeError(
            "Shared package differs from snapshot; review changes before --refresh"
        )
    print(
        json.dumps(
            {
                "domain": snapshot["domain"],
                "sharedFiles": len(actual),
                "standalone": True,
                "status": "passed",
            }
        )
    )


if __name__ == "__main__":
    main()
