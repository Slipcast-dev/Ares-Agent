#!/usr/bin/env python3
"""Лицензия и DMG с переносимыми иконками: без публикации и установки в систему."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from typing import Iterator

ROOT = Path(__file__).resolve().parents[1]


def run(arguments: list[str], timeout: int = 120) -> bytes:
    """Пути передаются аргументами, не интерпретируются оболочкой."""
    result = subprocess.run(
        arguments, check=True, capture_output=True, timeout=timeout
    )
    return result.stdout


def digest(path: Path) -> str:
    """Сумма относится к содержимому файла, без внешних Finder-метаданных."""
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


@contextmanager
def mounted(
    image: Path, mount: Path, readonly: bool = False
) -> Iterator[Path]:
    """Отсоединяем только собственный образ даже при отказе проверки."""
    args = [
        "/usr/bin/hdiutil",
        "attach",
        str(image),
        "-nobrowse",
        "-noautoopen",
        "-mountpoint",
        str(mount),
    ]
    if readonly:
        args.append("-readonly")
    mount.mkdir()
    run(args)
    try:
        yield mount
    finally:
        run(["/usr/bin/hdiutil", "detach", str(mount)], timeout=45)


def custom_icon(path: Path) -> bool:
    """Проверяем и флаг custom icon, и непустой resource fork пакета."""
    info = bytes.fromhex(
        run(
            ["/usr/bin/xattr", "-px", "com.apple.FinderInfo", str(path)]
        ).decode()
    )
    return bool(int.from_bytes(info[8:10], "big") & 0x0400) and bool(
        run(["/usr/bin/xattr", "-p", "com.apple.ResourceFork", str(path)])
    )


def repack(
    app: Path, package: Path, metadata: dict[str, object], base: Path
) -> None:
    """Добавление LICENSE меняет seal приложения: подпись пересоздаём до pkgbuild."""
    shutil.copy2(ROOT / "LICENSE", app / "Contents/Resources/LICENSE")
    run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    payload = base / "payload"
    payload.mkdir()
    run(
        [
            "/usr/bin/ditto",
            "--rsrc",
            "--extattr",
            str(app),
            str(payload / app.name),
        ]
    )
    components = base / "components.plist"
    run(
        [
            "/usr/bin/pkgbuild",
            "--analyze",
            "--root",
            str(payload),
            str(components),
        ]
    )
    values = plistlib.loads(components.read_bytes())
    for value in values:
        value["BundleIsRelocatable"] = False
    components.write_bytes(plistlib.dumps(values))
    # Существующий установщик заменяется только после успешного формирования.
    replacement = base / package.name
    run(
        [
            "/usr/bin/pkgbuild",
            "--root",
            str(payload),
            "--install-location",
            "/Applications",
            "--identifier",
            str(metadata["bundleIdentifier"]),
            "--version",
            str(metadata["version"]),
            "--component-plist",
            str(components),
            "--ownership",
            "recommended",
            str(replacement),
        ]
    )
    shutil.copyfile(replacement, package)


def main() -> None:
    """Проверяем DMG после копирования только data fork, как при скачивании."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update-license", action="store_true")
    args = parser.parse_args()
    metadata = json.loads((ROOT / "snapshot.json").read_text())
    name = metadata["name"]
    package = ROOT / (name + "-E10-arm64-local.pkg")
    image = ROOT / (name + "-E10-arm64-local.dmg")
    license_bytes = (ROOT / "LICENSE").read_bytes()
    with tempfile.TemporaryDirectory(
        prefix="agent-distribution-", dir="/private/tmp"
    ) as temporary:
        base = Path(temporary)
        expanded = base / "expanded"
        run(
            ["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)]
        )
        apps = list(expanded.rglob(metadata["appName"] + ".app"))
        if len(apps) != 1:
            raise RuntimeError("Expected one standalone application")
        app = apps[0]
        included = app / "Contents/Resources/LICENSE"
        if not included.is_file() or included.read_bytes() != license_bytes:
            if not args.update_license:
                raise RuntimeError(
                    "Package license differs: explicitly use --update-license"
                )
            repack(app, package, metadata, base)
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        icon_name = plistlib.loads((app / "Contents/Info.plist").read_bytes())[
            "CFBundleIconFile"
        ]
        icon = app / "Contents/Resources" / icon_name
        if icon.read_bytes()[:4] != b"icns":
            raise RuntimeError("Missing valid ICNS")
        helper = base / "SetInstallerIcon"
        run(
            [
                "swiftc",
                str(ROOT / "scripts/SetInstallerIcon.swift"),
                "-target",
                "arm64-apple-macosx14.0",
                "-o",
                str(helper),
            ]
        )
        run([str(helper), str(icon), str(package)])
        if not custom_icon(package):
            raise RuntimeError("Package custom icon missing")
        # Пустой UDIF по умолчанию read/write; -format применяется
        # только к образу из папки/устройства или последующему convert.
        writable = base / "writable.dmg"
        size_mb = max(64, package.stat().st_size // (1024 * 1024) * 3 + 32)
        run(
            [
                "/usr/bin/hdiutil",
                "create",
                "-size",
                str(size_mb) + "m",
                "-fs",
                "HFS+",
                "-volname",
                name + " — Установка",
                str(writable),
            ]
        )
        with mounted(writable, base / "write-volume") as volume:
            run(
                [
                    "/usr/bin/ditto",
                    "--rsrc",
                    "--extattr",
                    str(package),
                    str(volume / package.name),
                ]
            )
            shutil.copy2(icon, volume / ".VolumeIcon.icns")
            run(["/usr/bin/SetFile", "-a", "C", str(volume)])
            (volume / "ЛИЦЕНЗИЯ.md").write_bytes(license_bytes)
            (volume / "УСТАНОВКА.txt").write_text(
                name + " — промежуточная версия E10\n\n"
                "Откройте " + package.name + " и следуйте шагам Installer.\n"
                "Apple Silicon, macOS14+, Python3. Подпись локальная ad-hoc; Developer ID/notarization отсутствуют.\n"
                "Системные разрешения выдаются вручную. Глобальные подключения и личные данные не переносятся автоматически.\n"
                "Лицензия находится рядом и внутри устанавливаемого приложения.\n"
            )
            if not custom_icon(volume / package.name):
                raise RuntimeError("Copy lost package resource fork")
        final = base / image.name
        run(
            [
                "/usr/bin/hdiutil",
                "convert",
                str(writable),
                "-format",
                "UDZO",
                "-imagekey",
                "zlib-level=9",
                "-o",
                str(final),
            ]
        )
        run(["/usr/bin/hdiutil", "verify", str(final)])
        shutil.copyfile(final, image)
        # Внешняя иконка DMG удобна на этом Mac. Переносимость доказывается
        # отдельно: в образе находятся volume icon и Finder-метаданные pkg.
        run([str(helper), str(icon), str(image)])
        downloaded = base / "downloaded.dmg"
        with image.open("rb") as source, downloaded.open("wb") as target:
            shutil.copyfileobj(source, target)
        # macOS может автоматически назначить provenance/quarantine новому
        # файлу. Для этой проверки существенны только метаданные иконки:
        # они не должны попасть во внешний скачанный DMG.
        attributes = set(
            run(["/usr/bin/xattr", str(downloaded)]).decode().splitlines()
        )
        if attributes & {"com.apple.FinderInfo", "com.apple.ResourceFork"}:
            raise RuntimeError(
                "Download simulation retained external icon metadata"
            )
        with mounted(
            downloaded, base / "read-volume", readonly=True
        ) as volume:
            if digest(volume / package.name) != digest(
                package
            ) or not custom_icon(volume / package.name):
                raise RuntimeError(
                    "Downloaded image lost installer content or icon"
                )
            info = bytes.fromhex(
                run(
                    [
                        "/usr/bin/xattr",
                        "-px",
                        "com.apple.FinderInfo",
                        str(volume),
                    ]
                ).decode()
            )
            if not int.from_bytes(info[8:10], "big") & 0x0400:
                raise RuntimeError("Volume custom icon missing")
            if (volume / ".VolumeIcon.icns").read_bytes() != icon.read_bytes():
                raise RuntimeError("Volume icon differs")
            if (volume / "ЛИЦЕНЗИЯ.md").read_bytes() != license_bytes:
                raise RuntimeError("Distribution license differs")
            second = base / "downloaded-pkg"
            run(
                [
                    "/usr/sbin/pkgutil",
                    "--expand-full",
                    str(volume / package.name),
                    str(second),
                ]
            )
            copied_app = next(second.rglob(metadata["appName"] + ".app"))
            if (
                copied_app / "Contents/Resources/LICENSE"
            ).read_bytes() != license_bytes:
                raise RuntimeError("Installed license differs")
            run(
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--deep",
                    "--strict",
                    str(copied_app),
                ]
            )
        (ROOT / "SHA256SUMS.txt").write_text(
            "".join(
                digest(path) + "  " + path.name + "\n"
                for path in [package, image]
            )
        )
        report = {
            "status": "passed",
            "domain": metadata["domain"],
            "licenseIncludedInPackage": True,
            "packageCustomIcon": True,
            "volumeCustomIcon": True,
            "dataOnlyDownloadSimulation": True,
            "downloadedInstallerIconPreserved": True,
            "downloadedPackageSignatureValid": True,
            "sourceAndPackagedLicenseMatch": True,
            "allOwnVolumesDetached": True,
            "notarized": False,
            "developerIDSigned": False,
            "outerDMGCustomIconPortable": False,
            "artifacts": {
                path.name: {
                    "sha256": digest(path),
                    "bytes": path.stat().st_size,
                }
                for path in [package, image]
            },
        }
        (ROOT / "distribution-verification.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )
        print(
            json.dumps(
                {
                    "domain": metadata["domain"],
                    "status": "passed",
                    "dmg": image.name,
                    "iconsAfterDownload": True,
                }
            )
        )


if __name__ == "__main__":
    main()
