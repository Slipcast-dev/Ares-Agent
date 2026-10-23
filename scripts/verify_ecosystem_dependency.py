#!/usr/bin/env python3
"""Проверяет локальный vendored EcosystemKit без соседнего репозитория."""
from __future__ import annotations
import hashlib
import json
import re
from pathlib import Path


def main() -> None:
    """Сверяем весь набор файлов, включая лишние/удалённые, до сборки."""
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / "EcosystemKit.lock.json").read_text())
    package = root / "Packages/EcosystemKit"
    actual = {}
    for path in package.rglob("*"):
        if any(p in {".build", ".swiftpm", "__pycache__"} for p in path.relative_to(package).parts):
            continue
        if path.is_symlink():
            raise RuntimeError("Symlink in vendored dependency")
        if path.is_file() and path.name != ".DS_Store" and path.suffix != ".pyc":
            actual[path.relative_to(package).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    expected = {entry["path"]: entry["sha256"] for entry in lock["files"]}
    if actual != expected or not actual:
        raise RuntimeError("Vendored dependency differs from reviewed lock")
    print(json.dumps({"packageVersion": lock["packageVersion"], "checkedFiles": len(actual)}))


if __name__ == "__main__":
    main()
