#!/usr/bin/env python3
"""Подготовка локальных unsigned PKG/DMG; установка и публикация отсутствуют.

Два отдельных приложения проверяются после реального извлечения PKG и из
read-only DMG. Наличие этих артефактов не доказывает production activation:
автозапуск, миграция рабочего профиля и выдача grants требуют отдельной приёмки.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from typing import Any

from localized_distribution import validate_metadata, write_installer_resources, verify_installer_resources

WORKSPACE = Path(__file__).resolve().parents[2]
PRODUCTS = {
    "Ares": (
        "FileOrganizer",
        "FileOrganizerMCP",
        "AresRuntime",
        "FileOrganizerRulesWorker",
        "FileOrganizerAres.icns",
    ),
    "Athena": (
        "MacAssistant",
        "MacAssistantMCP",
        "AthenaRuntime",
        None,
        "Athena.icns",
    ),
}


def command(
    arguments: list[str], **options: Any
) -> subprocess.CompletedProcess[str]:
    """Без shell: Unicode/пробелы в путях не интерпретируются как команды."""
    return subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
        timeout=900,
        **options,
    )


def digest(file: Path) -> str:
    """Потоковое чтение не делает размер DMG дополнительным расходом RSS."""
    value = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def inventory(app: Path) -> dict[str, str]:
    """Seal и ресурсы сравниваются по байтам, а не только по размеру приложения."""
    return {
        str(file.relative_to(app)): digest(file)
        for file in sorted(app.rglob("*"))
        if file.is_file()
    }


def validate(app: Path, name: str, version: str) -> dict[str, Any]:
    """Наличие всех helpers обязательно; одна подпись внешнего bundle недостаточна."""
    metadata = validate_metadata(app, name)
    gui, mcp, runtime, worker, icon = PRODUCTS[name]
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info.get("CFBundleShortVersionString") != version:
        raise RuntimeError("Unexpected artifact version")
    background = contents / "Library/LoginItems" / (name + "Background.app")
    background_info = plistlib.loads(
        (background / "Contents/Info.plist").read_bytes()
    )
    if (
        not background_info.get("LSUIElement")
        or background_info.get("CFBundleExecutable") != runtime
    ):
        raise RuntimeError("Invalid background bundle")
    # Центр уведомлений использует identity вложенного отправителя. Проверка
    # до codesign даёт точную причину и запрещает выпуск с пустой иконкой.
    helper_icon = background / "Contents/Resources" / icon
    main_icon = contents / "Resources" / icon
    if (
        background_info.get("CFBundleIconFile") != icon
        or background_info.get("CFBundleShortVersionString") != version
        or not helper_icon.is_file()
        or not main_icon.is_file()
        or digest(helper_icon) != digest(main_icon)
    ):
        raise RuntimeError("Missing or mismatched background notification icon/version")
    binaries = [
        contents / "MacOS" / gui,
        contents / "MacOS" / mcp,
        contents / "MacOS" / (name + "Maintenance"),
        background / "Contents/MacOS" / runtime,
    ]
    if worker:
        binaries.append(contents / "MacOS" / worker)
    architectures: dict[str, str] = {}
    for binary in binaries:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError("Missing executable")
        command(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
        architectures[binary.name] = command(
            ["/usr/bin/lipo", "-archs", str(binary)]
        ).stdout.strip()
        dependencies = command(
            ["/usr/bin/otool", "-L", str(binary)]
        ).stdout.splitlines()[1:]
        # Абсолютная ссылка на .build/папку разработчика сломала бы перенос.
        if any(
            not line.strip().startswith(
                (
                    "/System/Library/",
                    "/usr/lib/",
                    "@rpath/",
                    "@loader_path/",
                    "@executable_path/",
                )
            )
            for line in dependencies
        ):
            raise RuntimeError("Nonportable dynamic library dependency")
    if not (contents / "Resources" / icon).is_file():
        raise RuntimeError("Missing app icon")
    for resources in [
        contents / "Resources",
        background / "Contents/Resources",
    ]:
        if not (resources / "EcosystemKit_EcosystemContracts.bundle").is_dir():
            raise RuntimeError("Missing contract resources")
        for language in ("ru", "en"):
            for table in ("Localizable.strings", "Localizable.stringsdict", "Shared.strings", "Runtime.strings"):
                bundle = resources / "EcosystemKit_EcosystemLocalization.bundle"
                if not any((base / (language + ".lproj") / table).is_file()
                           for base in (bundle, bundle / "Contents/Resources")):
                    raise RuntimeError("Missing localization resources")
    if name == "Athena":
        # Отдельный каталог GUI нельзя заменить общим Kit или developer .build.
        own = contents / "Resources/MacAssistant_MacAssistant.bundle"
        for language in ("ru", "en"):
            if not any((base / (language + ".lproj") / "Athena.strings").is_file()
                       for base in (own, own / "Contents/Resources")):
                raise RuntimeError("Missing Athena localization resources")
    if not (contents / "Resources/ProfileLifecycle.md").is_file():
        raise RuntimeError("Missing installation/removal instructions")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signing = command(["/usr/bin/codesign", "-dvv", str(app)]).stderr
    if "Signature=adhoc" not in signing:
        raise RuntimeError("Local unsigned pipeline requires an ad-hoc app")
    return {
        "macOSLocalization": metadata,
        "architectures": architectures,
        "nestedSignaturesVerified": True,
        "contractResourcesPresent": True,
        "iconPresent": True,
        "backgroundNotificationIconMatchesApplication": True,
        "developerIDSigned": False,
        "notarized": False,
        "automaticActivationInstalled": False,
    }


def verify_resource_probes(app: Path, name: str) -> None:
    """Ранний флаг GUI/runtime выходит до bootstrap; macOS settings не меняются."""
    gui, _, runtime, _, _ = PRODUCTS[name]
    binaries = [app / "Contents/MacOS" / gui,
                app / "Contents/Library/LoginItems" / (name + "Background.app") / "Contents/MacOS" / runtime]
    for binary in binaries:
        result = json.loads(command([str(binary), "--localization-probe"]).stdout)
        if {item["language"] for item in result["samples"]} != {"ru", "en"}:
            raise RuntimeError("Packaged executable lacks a supported locale")
        for sample in result["samples"]:
            if not (sample["resourcesAvailable"] and sample["runtimeComplete"] and sample["sharedComplete"]
                    and sample["resourcePlacement"] == "application"):
                raise RuntimeError("Packaged executable used missing/developer localization resources")


def main() -> None:
    """Новый output сохраняет прошлые сборки; finally отмонтирует только свой DMG."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--version", default="0.37.0")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--use-prepared-apps",
        action="store_true",
        help="Do not build; still require exact versions, contents and signatures",
    )
    parser.add_argument("--apps-dir", type=Path, help="Explicit prepared applications directory; never installed")
    parser.add_argument("--agent", choices=tuple(PRODUCTS), help="Package just one prepared standalone agent")
    args = parser.parse_args()
    if not args.run or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", args.version
    ):
        parser.error("--run and numeric semantic version required")
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    report: dict[str, Any] = {
        "version": args.version,
        "status": "preparing",
        "artifacts": {},
        "productionReady": False,
        "installed": False,
        "published": False,
        "remainingGates": [
            "production-activation-and-clean-machine",
            "Developer-ID-and-notarization",
            "real-sleep-login",
            "macOS14-and-Intel",
            "VoiceOver-and-visible-notification",
            "active-24h-soak",
        ],
    }
    environment = {
        **os.environ,
        "ECOSYSTEM_APP_VERSION": args.version,
        "ECOSYSTEM_SKIP_LSREGISTER": "1",
        **({"ECOSYSTEM_APP_OUTPUT_DIR": str(args.apps_dir.absolute())} if args.apps_dir else {}),
    }
    try:
        for name, (project, *_) in PRODUCTS.items():
            if args.agent and name != args.agent:
                continue
            if not args.use_prepared_apps:
                script = (
                    WORKSPACE
                    / project
                    / (
                        "scripts/package_app.zsh"
                        if name == "Ares"
                        else "script/build_and_run.sh"
                    )
                )
                arguments = [str(script)] + (
                    ["--package"] if name == "Athena" else []
                )
                result = command(
                    arguments, cwd=WORKSPACE / project, env=environment
                )
                (output / (name + "-build.log")).write_text(
                    result.stdout + result.stderr
                )
            source = (args.apps_dir.absolute() if args.apps_dir else WORKSPACE / "Приложения") / (name + ".app")
            with tempfile.TemporaryDirectory(
                prefix="e13-release-", dir="/private/tmp"
            ) as temporary:
                base = Path(temporary)
                payload = base / "payload"
                app = payload / "Applications" / (name + ".app")
                app.parent.mkdir(parents=True)
                command(
                    [
                        "/usr/bin/ditto",
                        "--norsrc",
                        "--noextattr",
                        str(source),
                        str(app),
                    ]
                )
                details = validate(app, name, args.version)
                expected = inventory(app)
                components = base / "components.plist"
                command(
                    [
                        "/usr/bin/pkgbuild",
                        "--analyze",
                        "--root",
                        str(payload),
                        str(components),
                    ]
                )
                values = plistlib.loads(components.read_bytes())
                # Обновление не должно искать и заменять случайную development
                # копию с тем же bundle ID. Нет scripts, launchd файлов или sudo.
                for component in values:
                    component["BundleIsRelocatable"] = False
                components.write_bytes(plistlib.dumps(values))
                pkg = output / f"{name}-{args.version}-unsigned.pkg"
                component_pkg = base / (name + "-component.pkg")
                command(
                    [
                        "/usr/bin/pkgbuild",
                        "--root",
                        str(payload),
                        "--component-plist",
                        str(components),
                        "--identifier",
                        "local.ecosystem." + name.lower() + ".preview",
                        "--version",
                        args.version,
                        "--install-location",
                        "/",
                        str(component_pkg),
                    ]
                )
                # Product archive добавляет только локализованные страницы.
                # Payload/идентификатор компонента и отсутствие install scripts
                # сохраняются; системный installer здесь никогда не запускается.
                distribution = base / "Distribution.xml"
                command(["/usr/bin/productbuild", "--synthesize", "--package", str(component_pkg), str(distribution)])
                tree = ET.parse(distribution)
                root = tree.getroot()
                ET.SubElement(root, "title").text = name
                ET.SubElement(root, "welcome", {"file": "Welcome.html", "mime-type": "text/html"})
                ET.SubElement(root, "readme", {"file": "ReadMe.html", "mime-type": "text/html"})
                tree.write(distribution, encoding="utf-8", xml_declaration=True)
                resources = base / "installer-resources"
                installer_texts = write_installer_resources(resources, name, args.version)
                command(["/usr/bin/productbuild", "--distribution", str(distribution), "--resources", str(resources), "--package-path", str(base), str(pkg)])
                expanded = base / "expanded"
                command(
                    [
                        "/usr/sbin/pkgutil",
                        "--expand-full",
                        str(pkg),
                        str(expanded),
                    ]
                )
                extracted = [
                    path
                    for path in expanded.rglob(name + ".app")
                    if path.parent.name == "Applications"
                ]
                if len(extracted) != 1 or inventory(extracted[0]) != expected:
                    raise RuntimeError(
                        "PKG roundtrip differs from prepared app"
                    )
                validate(extracted[0], name, args.version)
                verify_installer_resources(expanded, installer_texts)
                verify_resource_probes(extracted[0], name)
                if any(
                    path.name in {"preinstall", "postinstall"}
                    for path in expanded.rglob("*")
                ):
                    raise RuntimeError(
                        "Unexpected installer activation script"
                    )
                signature = subprocess.run(
                    ["/usr/sbin/pkgutil", "--check-signature", str(pkg)],
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                if (
                    signature.returncode == 0
                    or "no signature"
                    not in signature.stdout + signature.stderr
                ):
                    raise RuntimeError("Unexpected PKG signature state")
                image_root = base / "image"
                image_root.mkdir()
                command(
                    [
                        "/usr/bin/ditto",
                        "--norsrc",
                        "--noextattr",
                        str(app),
                        str(image_root / app.name),
                    ]
                )
                (image_root / "Applications").symlink_to("/Applications")
                (image_root / "README.txt").write_text(
                    f"{name} {args.version} — local preview / локальная проверочная сборка\n"
                    "Без Developer ID и notarization / No Developer ID signature or notarization.\n"
                    "Установка не включает агентов автоматически и не выдаёт доступ к данным.\n"
                    "Installation does not activate background agents or grant data access.\n"
                    "Откройте приложение: оно запустит свою службу без исходников.\n"
                    "Open the app to start its service without source code or workspace commands.\n"
                    "Инструкция по холодному обновлению: Contents/Resources/ProfileMaintenance.md внутри приложения.\n"
                    "Cold upgrade instructions: Contents/Resources/ProfileMaintenance.md inside the app.\n"
                    "Установка и удаление с сохранением данных: Contents/Resources/ProfileLifecycle.md.\n"
                    "Installation and data-preserving removal: Contents/Resources/ProfileLifecycle.md.\n"
                )
                dmg = output / f"{name}-{args.version}-unsigned.dmg"
                # Finder получает тематическую иконку и у тома, и у файлов
                # установщиков. Меняется только metadata подготовленных артефактов.
                icon = app / "Contents/Resources" / PRODUCTS[name][4]
                shutil.copy2(icon, image_root / ".VolumeIcon.icns")
                set_file = command(
                    ["/usr/bin/xcrun", "--find", "SetFile"]
                ).stdout.strip()
                command([set_file, "-a", "C", str(image_root)])
                command(
                    [
                        "/usr/bin/hdiutil",
                        "create",
                        "-srcfolder",
                        str(image_root),
                        "-volname",
                        name + " Local Preview",
                        "-format",
                        "UDZO",
                        str(dmg),
                    ]
                )
                command(["/usr/bin/hdiutil", "verify", str(dmg)])
                mount = base / "Проверка переноса Ω"
                mount.mkdir()
                mounted = False
                try:
                    command(
                        [
                            "/usr/bin/hdiutil",
                            "attach",
                            "-readonly",
                            "-nobrowse",
                            "-mountpoint",
                            str(mount),
                            str(dmg),
                        ]
                    )
                    mounted = True
                    validate(mount / app.name, name, args.version)
                    verify_resource_probes(mount / app.name, name)
                    if inventory(mount / app.name) != expected:
                        raise RuntimeError(
                            "DMG roundtrip differs from prepared app"
                        )
                finally:
                    if mounted:
                        command(["/usr/bin/hdiutil", "detach", str(mount)])
                icon_script = base / "InstallerIcon.swift"
                icon_script.write_text(
                    "import AppKit\nimport Darwin\nlet a = CommandLine.arguments\nguard let icon = NSImage(contentsOfFile: a[1]) else { exit(65) }\nfor file in a.dropFirst(2) { guard NSWorkspace.shared.setIcon(icon, forFile: file, options: []) else { exit(66) } }\n"
                )
                command(
                    [
                        "/usr/bin/swift",
                        str(icon_script),
                        str(icon),
                        str(pkg),
                        str(dmg),
                    ]
                )
                details.update(
                    {
                        "customInstallerIconsSet": True,
                        "volumeIconSet": True,
                        "installerLocales": ["ru", "en"],
                        "installerResourcesVerifiedAfterExtraction": True,
                        "guiRuntimeProbesAfterPKGAndDMG": True,
                        "pkgRoundtrip": True,
                        "dmgRoundtrip": True,
                        "pkg": {
                            "file": pkg.name,
                            "sha256": digest(pkg),
                            "bytes": pkg.stat().st_size,
                        },
                        "dmg": {
                            "file": dmg.name,
                            "sha256": digest(dmg),
                            "bytes": dmg.stat().st_size,
                        },
                    }
                )
                report["artifacts"][name] = details
        report["status"] = "local-artifacts-verified-production-gates-open"
        sums = [
            f"{info[kind]['sha256']}  {info[kind]['file']}"
            for info in report["artifacts"].values()
            for kind in ["pkg", "dmg"]
        ]
        (output / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    except BaseException as error:
        report["status"] = "failed"
        report["failureType"] = type(error).__name__
        raise
    finally:
        (output / "release-manifest.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )
    print(
        json.dumps(
            {"status": report["status"], "artifacts": len(report["artifacts"])}
        )
    )


if __name__ == "__main__":
    main()
