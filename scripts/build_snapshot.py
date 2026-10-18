#!/usr/bin/env python3
"""Собирает локальный автономный .app/pkg/DMG без обращения к соседнему проекту."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(arguments: list[str]) -> None:
    """Без shell: пробелы/кириллица в путях не становятся исполняемым текстом."""
    subprocess.run(arguments, cwd=ROOT, check=True)


def main() -> None:
    """pkg только кладёт bundle; ни postinstall, ни автоматической выдачи прав."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configuration", choices=["debug", "release"], default="release"
    )
    args = parser.parse_args()
    if platform.machine() != "arm64":
        raise RuntimeError(
            "This intermediate installer supports Apple Silicon only"
        )
    run(["/usr/bin/python3", str(ROOT / "scripts/verify_snapshot.py")])
    run(["swift", "build", "-c", args.configuration])
    products = Path(
        subprocess.check_output(
            ["swift", "build", "-c", args.configuration, "--show-bin-path"],
            cwd=ROOT,
            text=True,
        ).strip()
    )
    metadata = json.loads((ROOT / "snapshot.json").read_text())
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    artifacts = ROOT / ".artifacts"
    artifacts.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="package-", dir=artifacts
    ) as temporary:
        base = Path(temporary)
        payload = base / "payload"
        app = payload / (metadata["appName"] + ".app")
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        names = [metadata["native"], metadata["mcp"], metadata["runtime"]] + (
            [metadata["worker"]] if metadata["worker"] else []
        )
        for name in names:
            shutil.copy2(products / name, macos / name)
            run(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    "-",
                    str(macos / name),
                ]
            )
        # Bundle.module должен находить ресурсы и при отсутствии каталога сборки.
        for path in products.glob("*.bundle"):
            shutil.copytree(path.resolve(), resources / path.name)
        for name in ["local_runtime.py", "snapshot_entry.py"]:
            shutil.copy2(ROOT / "scripts" / name, resources / name)
        for name in ["snapshot.json", "THIRD_PARTY_NOTICES.md", "LICENSE"]:
            if (ROOT / name).is_file():
                shutil.copy2(ROOT / name, resources / name)
        iconset = base / "AppIcon.iconset"
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                name = (
                    f"icon_{size}x{size}"
                    + ("@2x" if scale == 2 else "")
                    + ".png"
                )
                run(
                    [
                        "/usr/bin/sips",
                        "-z",
                        str(size * scale),
                        str(size * scale),
                        str(ROOT / metadata["iconSource"]),
                        "--out",
                        str(iconset / name),
                    ]
                )
        icon = (
            "FileOrganizerAres.icns"
            if metadata["domain"] == "ares"
            else "Athena.icns"
        )
        run(
            [
                "/usr/bin/iconutil",
                "-c",
                "icns",
                str(iconset),
                "-o",
                str(resources / icon),
            ]
        )
        # Нативный executable позволяет корректно подписать внешний app bundle;
        # профиль и фоновая работа остаются у отдельных GUI/runtime executable.
        run(
            [
                "swiftc",
                str(ROOT / "scripts/SnapshotLauncher.swift"),
                "-target",
                "arm64-apple-macosx14.0",
                "-o",
                str(macos / "SnapshotLauncher"),
            ]
        )
        info = {
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "SnapshotLauncher",
            "CFBundleIdentifier": metadata["bundleIdentifier"],
            "CFBundleName": metadata["appName"],
            "CFBundleDisplayName": metadata["appName"],
            "CFBundleVersion": "20261018",
            "CFBundleShortVersionString": metadata["version"],
            "CFBundleIconFile": icon,
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": True,
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        destination = output / app.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(app, destination)
        # Все компоненты привязаны к /Applications этого пакета. Installer
        # не должен найти одноимённый resource bundle в исходной экосистеме.
        component_file = base / "components.plist"
        run(
            [
                "/usr/bin/pkgbuild",
                "--analyze",
                "--root",
                str(payload),
                str(component_file),
            ]
        )
        components = plistlib.loads(component_file.read_bytes())
        for component in components:
            component["BundleIsRelocatable"] = False
        component_file.write_bytes(plistlib.dumps(components))
        installer = ROOT / (metadata["name"] + "-E10-arm64-local.pkg")
        run(
            [
                "/usr/bin/pkgbuild",
                "--root",
                str(payload),
                "--install-location",
                "/Applications",
                "--identifier",
                metadata["bundleIdentifier"],
                "--version",
                metadata["version"],
                "--component-plist",
                str(component_file),
                "--ownership",
                "recommended",
                str(installer),
            ]
        )
        run(
            ["/usr/bin/python3", str(ROOT / "scripts/package_distribution.py")]
        )
        checksum = hashlib.sha256(installer.read_bytes()).hexdigest()
        print(
            json.dumps(
                {
                    "installer": installer.name,
                    "sha256": checksum,
                    "signature": "ad-hoc",
                    "notarized": False,
                }
            )
        )


if __name__ == "__main__":
    main()
