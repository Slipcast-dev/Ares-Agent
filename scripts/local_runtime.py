#!/usr/bin/env python3
"""Явный локальный профиль двух отдельных агентов без Developer ID и без sudo."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import shlex
import stat
import subprocess
import time
from typing import Any, Iterator
import uuid

SOURCE_APP = Path(__file__).resolve().parents[2]
PRODUCTS = {
    "ares": (
        "FileOrganizer",
        "FileOrganizer",
        "FileOrganizerMCP",
        "AresRuntime",
        "FileOrganizerRulesWorker",
        "Ares",
        "dev.slipcast.fileorganizer.intermediate",
    )
}


def run(
    arguments: list[str],
    *,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Без shell; вывод дочернего процесса не смешивается с JSON/MCP stdout."""
    # kickstart может ждать штатный ThrottleInterval=30 после SIGTERM/crash.
    # Это ограниченное ожидание launchd, а не повторный запуск в цикле.
    timeout = 45 if arguments[:2] == ["/bin/launchctl", "kickstart"] else 20
    return subprocess.run(
        arguments,
        check=check,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


def private_directory(path: Path) -> None:
    """Не исправляем права чужого каталога автоматически и не следуем symlink."""
    if path.is_symlink():
        raise RuntimeError("Profile directory is a symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise RuntimeError(
            "Profile directory must be owned and private (0700)"
        )


def write_private(path: Path, value: bytes) -> None:
    """Атомарно заменяем только служебный файл управляемого профиля."""
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o077
        ):
            raise RuntimeError("Unsafe profile file")
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    # fsync каталога фиксирует rename, а не только содержимое временного файла.
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def requirement(binary: Path) -> str:
    """Точное pinning: смена бинарника требует остановки и обновления профиля."""
    run(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
    output = run(["/usr/bin/codesign", "-dvvv", str(binary)]).stderr
    match = re.search(r"^CDHash=([0-9a-fA-F]{40})$", output, re.MULTILINE)
    if match is None:
        raise RuntimeError("Binary has no exact CDHash")
    return 'cdhash H"' + match.group(1) + '"'


def manifest(profile: Path) -> dict[str, Any]:
    """Проверяем маркер перед stop/replace, чтобы не управлять чужими jobs."""
    info = profile.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        raise RuntimeError("Unsafe managed profile directory")
    path = profile / "profile.json"
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Managed profile marker is missing")
    info = path.stat()
    if (
        info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_size > 1048576
        or stat.S_IMODE(info.st_mode) & 0o077
    ):
        raise RuntimeError("Unsafe profile marker")
    value = json.loads(path.read_text())
    if (
        value.get("version") != 1
        or value.get("uid") != os.getuid()
        or set(value.get("agents", {})) != set(PRODUCTS)
    ):
        raise RuntimeError("Unsupported profile marker")
    if re.fullmatch(r"[0-9a-f]{32}", str(value.get("identifier", ""))) is None:
        raise RuntimeError("Unsupported profile identifier")
    persistent = value.get("persistent", {})
    if (
        not isinstance(persistent, dict)
        or not set(persistent).issubset(PRODUCTS)
        or any(
            not isinstance(path, str) or not Path(path).is_absolute()
            for path in persistent.values()
        )
    ):
        raise RuntimeError("Invalid persistence mapping")
    for domain, item in value["agents"].items():
        if (
            item["label"]
            != f"local.ecosystem.{domain}.{os.getuid()}.{value['identifier']}"
        ):
            raise RuntimeError("Unexpected launchd label")
    return value


def job_running(label: str) -> bool:
    """Launchctl проверяется только по точному Label из собственного маркера."""
    result = run(
        ["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], check=False
    )
    return (
        result.returncode == 0
        and re.search(r"\bpid = [1-9][0-9]*", result.stdout) is not None
    )


@contextmanager
def persistence_lock(profile: Path) -> Iterator[None]:
    """Общий с двумя GUI lock не позволяет потерять чужой domain при read-modify-write.

    LOCK_NB возвращает понятную ошибку вместо ожидания, блокирующего интерфейс.
    Файл lock сохраняется: удаление создало бы два разных inode и ложную защиту.
    """
    manifest(profile)
    descriptor = os.open(
        profile / ".persistence.lock",
        os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
        0o600,
    )
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o077
        ):
            raise RuntimeError("Unsafe persistence lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Persistence registration is busy") from error
        try:
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def create_profile(
    profile: Path, *, test_profile: bool = False
) -> dict[str, Any]:
    """Обновление снимка сериализуется с CLI/GUI изменением общего маркера."""
    if (profile / "profile.json").exists():
        with persistence_lock(profile):
            return _create_profile(profile, test_profile=test_profile)
    # До первого маркера профиль не опубликован: GUI ещё не может его менять.
    return _create_profile(profile, test_profile=test_profile)


def _create_profile(
    profile: Path, *, test_profile: bool = False
) -> dict[str, Any]:
    """Копируем бинарники: последующая сборка проекта не меняет работающий pin."""
    private_directory(profile)
    migration = profile / "migration-ares.json"
    if migration.exists():
        info = migration.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
        ):
            raise RuntimeError("Unsafe migration journal")
        state = json.loads(migration.read_text()).get("state")
        if state not in {"installed", "rolledBack"}:
            raise RuntimeError(
                "Migration interrupted: rollback before starting agents"
            )
    marker = profile / "profile.json"
    if marker.exists():
        value = manifest(profile)
        if any(
            job_running(item["label"]) for item in value["agents"].values()
        ):
            return value
        for domain, saved in value.get("persistent", {}).items():
            directory = persistence_directory(
                value, Path(saved), test_profile=bool(value.get("testProfile"))
            )
            installed = directory / (
                value["agents"][domain]["label"] + ".plist"
            )
            if installed.exists() or installed.is_symlink():
                owned_plist(installed, profile_plist(profile, value, domain))
        # История/БД остаются, обновляется только снимок исполняемого кода.
        identifier = value["identifier"]
        persistent = value.get("persistent", {})
    else:
        if any(profile.iterdir()):
            raise RuntimeError("New profile directory must be empty")
        identifier = uuid.uuid4().hex
        persistent = {}
    if test_profile and not str(profile).startswith(
        "/private/tmp/ecosystem-e3b-"
    ):
        raise RuntimeError(
            "Test client allowlist is limited to synthetic /private/tmp profiles"
        )
    binaries = profile / ("binaries-" + uuid.uuid4().hex)
    apps = profile / ("apps-" + uuid.uuid4().hex)
    private_directory(binaries)
    private_directory(apps)
    value: dict[str, Any] = {
        "version": 1,
        "uid": os.getuid(),
        "identifier": identifier,
        "mode": "local-ad-hoc",
        "testProfile": test_profile,
        "agents": {},
        "persistent": persistent,
    }
    for domain, (
        project,
        gui,
        mcp,
        runtime,
        worker,
        public_name,
        bundle_id,
    ) in PRODUCTS.items():
        source = SOURCE_APP / "Contents/MacOS"
        domain_binaries = binaries / domain
        private_directory(domain_binaries)
        paths: dict[str, Path] = {}
        for product in [gui, mcp, runtime] + ([worker] if worker else []):
            target = domain_binaries / product
            shutil.copy2((source / product).resolve(strict=True), target)
            run(["/usr/bin/codesign", "--force", "--sign", "-", str(target)])
            paths[product] = target
        identified: dict[str, Path] = {}
        for principal in ("codex", "deepseekHarness"):
            target = domain_binaries / (mcp + "-" + principal)
            shutil.copy2(paths[mcp], target)
            # Разные signing identifiers дают разные CDHash даже для одного кода.
            # Подмена ENV/config не позволяет бинарнику Codex войти в Harness endpoint.
            run(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    "local.ecosystem." + domain + ".mcp." + principal,
                    str(target),
                ]
            )
            identified[principal] = target
        bundle = apps / (public_name + ".app")
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        shutil.copy2(paths[gui], contents / "MacOS" / gui)
        for resources in (SOURCE_APP / "Contents/Resources").glob("*.bundle"):
            shutil.copytree(
                resources.resolve(), contents / "Resources" / resources.name
            )
        icon_name = (
            "FileOrganizerAres.icns" if domain == "ares" else "Athena.icns"
        )
        icon_source = SOURCE_APP / "Contents/Resources" / icon_name
        if icon_source.is_file():
            shutil.copy2(icon_source, contents / "Resources" / icon_name)
        info = {
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": gui,
            "CFBundleIdentifier": bundle_id,
            "CFBundleName": public_name,
            "CFBundleDisplayName": public_name,
            "CFBundleVersion": "300",
            "CFBundleShortVersionString": (
                "0.1.0" if domain == "ares" else "0.1.5"
            ),
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
        }
        if icon_source.is_file():
            info["CFBundleIconFile"] = icon_name
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)])
        run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--deep",
                "--strict",
                str(bundle),
            ]
        )
        # UserNotifications требует самостоятельного app bundle для фонового
        # процесса. Стабильный identifier сохраняет выбранные разрешения между
        # обновлениями снимка; CDHash pinning вычисляем уже по этому executable.
        runtime_bundle = apps / (public_name + " Background.app")
        runtime_contents = runtime_bundle / "Contents"
        (runtime_contents / "MacOS").mkdir(parents=True)
        runtime_executable = runtime_contents / "MacOS" / runtime
        shutil.copy2(paths[runtime], runtime_executable)
        runtime_identifier = (
            "local.ecosystem." + domain + ".background." + identifier
        )
        runtime_info = {
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": runtime,
            "CFBundleIdentifier": runtime_identifier,
            "CFBundleName": public_name + " фоновые задачи",
            "CFBundleDisplayName": public_name + " фоновые задачи",
            "CFBundleVersion": "700",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": True,
            "NSPrincipalClass": "NSApplication",
        }
        (runtime_contents / "Info.plist").write_bytes(
            plistlib.dumps(runtime_info)
        )
        run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                runtime_identifier,
                str(runtime_bundle),
            ]
        )
        run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--deep",
                "--strict",
                str(runtime_bundle),
            ]
        )
        paths[runtime] = runtime_executable
        label = f"local.ecosystem.{domain}.{os.getuid()}.{identifier}"
        server_requirement = requirement(paths[runtime])
        gui_requirement = requirement(contents / "MacOS" / gui)
        clients = {
            "gui": gui_requirement,
            "mcp": requirement(paths[mcp]),
            "worker": (
                requirement(paths[worker]) if worker else gui_requirement
            ),
        }
        clients.update(
            {
                "mcp." + principal: requirement(binary)
                for principal, binary in identified.items()
            }
        )
        if test_profile:
            clients = {
                role: pinned + " or " + server_requirement
                for role, pinned in clients.items()
            }
        config = {
            "version": 1,
            "mode": "local-ad-hoc",
            "domain": domain,
            "serverRequirement": server_requirement,
            "endpoints": {
                role: {
                    "service": label + "." + role,
                    "clientRequirement": pinned,
                }
                for role, pinned in clients.items()
            },
        }
        config_file = profile / (domain + ".json")
        wrapper = (
            "#!/bin/sh\nexport "
            + domain.upper()
            + "_LOCAL_RUNTIME_CONFIG="
            + shlex.quote(str(config_file))
            + "\nexec "
            + shlex.quote(str(paths[mcp]))
            + "\n"
        )
        wrapper_file = profile / (domain + "-mcp.command")
        write_private(wrapper_file, wrapper.encode())
        wrapper_file.chmod(0o700)
        write_private(config_file, json.dumps(config, indent=2).encode())
        client_profiles: dict[str, dict[str, str]] = {}
        for principal, binary in identified.items():
            client_config = dict(config)
            client_config["selectedMCPClient"] = principal
            client_file = profile / (domain + "-" + principal + ".json")
            client_wrapper = profile / (
                domain + "-" + principal + "-mcp.command"
            )
            write_private(
                client_file, json.dumps(client_config, indent=2).encode()
            )
            script = (
                "#!/bin/sh\nexport "
                + domain.upper()
                + "_LOCAL_RUNTIME_CONFIG="
                + shlex.quote(str(client_file))
                + "\nexec "
                + shlex.quote(str(binary))
                + "\n"
            )
            write_private(client_wrapper, script.encode())
            client_wrapper.chmod(0o700)
            client_profiles[principal] = {
                "configuration": str(client_file),
                "mcp": str(binary),
                "wrapper": str(client_wrapper),
            }

        plist = {
            "Label": label,
            "ProgramArguments": [
                str(paths[runtime]),
                "--config",
                str(config_file),
            ],
            "MachServices": {
                endpoint["service"]: True
                for endpoint in config["endpoints"].values()
            },
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 30,
            "StandardOutPath": str(profile / (domain + "-runtime.stdout")),
            "StandardErrorPath": str(profile / (domain + "-runtime.stderr")),
        }
        write_private(profile / (domain + ".plist"), plistlib.dumps(plist))
        value["agents"][domain] = {
            "label": label,
            "configuration": str(config_file),
            "runtime": str(paths[runtime]),
            "mcp": str(paths[mcp]),
            "worker": str(paths[worker]) if worker else None,
            "bundle": str(bundle),
            "runtimeBundle": str(runtime_bundle),
            "clients": client_profiles,
            "binarySHA256": hashlib.sha256(
                paths[runtime].read_bytes()
            ).hexdigest(),
        }
    write_private(marker, json.dumps(value, indent=2).encode())
    refresh_persistence(profile, value)
    return value


def selected_domains(domains: list[str] | None) -> list[str]:
    """Выбор одного агента не должен менять регистрацию другого."""
    result = (
        list(PRODUCTS) if domains is None else list(dict.fromkeys(domains))
    )
    if not result or any(domain not in PRODUCTS for domain in result):
        raise RuntimeError("Unknown agent domain")
    return result


def persistence_directory(
    value: dict[str, Any], directory: Path | None, *, test_profile: bool
) -> Path:
    """Тестовый путь никогда не подменяет настоящий каталог Login Agents."""
    default = Path.home() / "Library/LaunchAgents"
    target = default if directory is None else directory.absolute()
    if target != default and (
        not test_profile
        or not value.get("testProfile")
        or not str(target).startswith("/private/tmp/ecosystem-e3b-")
    ):
        raise RuntimeError(
            "LaunchAgents override requires a synthetic test profile"
        )
    # Проверяем всю существующую цепочку: нельзя выйти через symlink родителя.
    for parent in [target, *target.parents]:
        if parent.is_symlink():
            raise RuntimeError("LaunchAgents directory contains a symlink")
    if target.exists():
        info = target.stat()
        if (
            not target.is_dir()
            or info.st_uid != os.getuid()
            or info.st_mode & 0o022
        ):
            raise RuntimeError("Unsafe LaunchAgents directory")
    return target


def owned_plist(path: Path, expected: dict[str, Any]) -> bytes:
    """Удалять/перезаписывать разрешено только точный собственный launchd job."""
    info = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_mode & 0o077
        or info.st_size > 65536
    ):
        raise RuntimeError("Unsafe persistence plist")
    data = path.read_bytes()
    if plistlib.loads(data) != expected:
        raise RuntimeError("Foreign or modified persistence plist")
    return data


def profile_plist(
    profile: Path, value: dict[str, Any], domain: str
) -> dict[str, Any]:
    """Сверяем пути и MachServices с маркером до любого внешнего изменения."""
    item = value["agents"][domain]
    expected_path = profile / (domain + ".plist")
    info = expected_path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_mode & 0o077
        or info.st_size > 65536
    ):
        raise RuntimeError("Unsafe profile plist")
    plist = plistlib.loads(expected_path.read_bytes())
    runtime = Path(item["runtime"])
    if not runtime.resolve(strict=True).is_relative_to(
        profile.resolve(strict=True)
    ) or Path(item["configuration"]) != profile / (domain + ".json"):
        raise RuntimeError("Runtime path escaped profile")
    services = {
        item["label"] + "." + role: True
        for role in (
            "gui",
            "mcp",
            "worker",
            "mcp.codex",
            "mcp.deepseekHarness",
        )
    }
    if (
        plist.get("Label") != item["label"]
        or plist.get("ProgramArguments")
        != [str(runtime), "--config", item["configuration"]]
        or plist.get("MachServices") != services
        or plist.get("RunAtLoad") is not True
        or plist.get("KeepAlive") != {"SuccessfulExit": False}
        or not isinstance(plist.get("ThrottleInterval"), int)
        or plist["ThrottleInterval"] < 30
        or plist.get("StandardOutPath")
        != str(profile / (domain + "-runtime.stdout"))
        or plist.get("StandardErrorPath")
        != str(profile / (domain + "-runtime.stderr"))
        or set(plist)
        != {
            "Label",
            "ProgramArguments",
            "MachServices",
            "RunAtLoad",
            "KeepAlive",
            "ThrottleInterval",
            "StandardOutPath",
            "StandardErrorPath",
        }
    ):
        raise RuntimeError("Unexpected profile launchd contract")
    return plist


def system_disabled(label: str) -> bool:
    """Читаем решение macOS; enable/disable не вызываем автоматически."""
    result = run(
        ["/bin/launchctl", "print-disabled", f"gui/{os.getuid()}"], check=False
    )
    if result.returncode != 0:
        raise RuntimeError("Cannot inspect launchd disabled state")
    # macOS версии выводят либо bool, либо слова enabled/disabled. Неизвестное
    # значение собственного label не трактуем как разрешение запустить службу.
    matched = re.search(
        r'"' + re.escape(label) + r'"\s*=>\s*([^\s,;}]+)', result.stdout
    )
    if matched is None:
        return False
    state = matched.group(1)
    if state not in {"true", "false", "disabled", "enabled"}:
        raise RuntimeError("Unknown launchd disabled state")
    return state in {"true", "disabled"}


def persistence_status(
    profile: Path,
    domains: list[str] | None = None,
    *,
    launch_agents_directory: Path | None = None,
    test_profile: bool = False,
) -> dict[str, Any]:
    """Configured, registered и running различаются после stop/отключения macOS."""
    value = manifest(profile)
    result: dict[str, Any] = {}
    for domain in selected_domains(domains):
        item = value["agents"][domain]
        saved = value.get("persistent", {}).get(domain)
        directory = persistence_directory(
            value,
            Path(saved) if saved else launch_agents_directory,
            test_profile=test_profile or bool(value.get("testProfile")),
        )
        path = directory / (item["label"] + ".plist")
        configured = False
        if path.exists() or path.is_symlink():
            owned_plist(path, profile_plist(profile, value, domain))
            configured = saved is not None
        target = f"gui/{os.getuid()}/{item['label']}"
        registered = (
            run(["/bin/launchctl", "print", target], check=False).returncode
            == 0
        )
        result[domain] = {
            "persistentConfigured": configured,
            "disabledBySystem": system_disabled(item["label"]),
            "registered": registered,
            "running": job_running(item["label"]),
        }
    return result


def enable_persistence(
    profile: Path,
    domains: list[str] | None = None,
    *,
    launch_agents_directory: Path | None = None,
    test_profile: bool = False,
) -> dict[str, Any]:
    """Только явный opt-in устанавливает файл для следующего входа пользователя."""
    with persistence_lock(profile):
        value = manifest(profile)
        directory = persistence_directory(
            value, launch_agents_directory, test_profile=test_profile
        )
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        for domain in selected_domains(domains):
            expected = profile_plist(profile, value, domain)
            saved = value.get("persistent", {}).get(domain)
            if saved is not None and Path(saved) != directory:
                raise RuntimeError(
                    "Disable previous persistence directory first"
                )
            path = directory / (value["agents"][domain]["label"] + ".plist")
            if path.exists() or path.is_symlink():
                if saved is None:
                    raise RuntimeError(
                        "Refusing to overwrite unowned LaunchAgent"
                    )
                owned_plist(path, expected)
            write_private(path, plistlib.dumps(expected))
            value.setdefault("persistent", {})[domain] = str(directory)
            write_private(
                profile / "profile.json", json.dumps(value, indent=2).encode()
            )
        return persistence_status(
            profile,
            domains,
            launch_agents_directory=directory,
            test_profile=test_profile,
        )


def disable_persistence(
    profile: Path,
    domains: list[str] | None = None,
    *,
    launch_agents_directory: Path | None = None,
    test_profile: bool = False,
) -> dict[str, Any]:
    """Удаляется только opt-in файл. Текущая работа и БД продолжают жить."""
    with persistence_lock(profile):
        value = manifest(profile)
        for domain in selected_domains(domains):
            saved = value.get("persistent", {}).get(domain)
            if saved is None:
                continue
            directory = persistence_directory(
                value,
                Path(saved),
                test_profile=test_profile or bool(value.get("testProfile")),
            )
            if (
                launch_agents_directory is not None
                and directory != launch_agents_directory.absolute()
            ):
                raise RuntimeError("Persistence directory mismatch")
            path = directory / (value["agents"][domain]["label"] + ".plist")
            if path.exists() or path.is_symlink():
                owned_plist(path, profile_plist(profile, value, domain))
                path.unlink()
            del value["persistent"][domain]
            write_private(
                profile / "profile.json", json.dumps(value, indent=2).encode()
            )
        return persistence_status(
            profile,
            domains,
            launch_agents_directory=launch_agents_directory,
            test_profile=test_profile,
        )


def refresh_persistence(profile: Path, value: dict[str, Any]) -> None:
    """Перед заменой снимка старый opt-in уже проверен; обновляем его пути."""
    for domain, saved in value.get("persistent", {}).items():
        directory = persistence_directory(
            value, Path(saved), test_profile=bool(value.get("testProfile"))
        )
        path = directory / (value["agents"][domain]["label"] + ".plist")
        # Отсутствующий файл означает отключение пользователем извне. Не
        # восстанавливаем его скрыто при обычном start.
        if path.exists():
            write_private(
                path, plistlib.dumps(profile_plist(profile, value, domain))
            )


def stop(profile: Path) -> dict[str, bool]:
    """Не удаляем БД, разрешения или чужие jobs: только bootout своих двух labels."""
    value = manifest(profile)
    result: dict[str, bool] = {}
    for domain, item in value["agents"].items():
        run(
            [
                "/bin/launchctl",
                "bootout",
                f"gui/{os.getuid()}/{item['label']}",
            ],
            check=False,
        )
        deadline = time.monotonic() + 8
        while True:
            missing = (
                run(
                    [
                        "/bin/launchctl",
                        "print",
                        f"gui/{os.getuid()}/{item['label']}",
                    ],
                    check=False,
                ).returncode
                != 0
            )
            if missing or time.monotonic() >= deadline:
                result[domain] = missing
                break
            time.sleep(0.1)
    if not all(result.values()):
        raise RuntimeError("Local jobs cleanup failed")
    return result


def start(profile: Path, *, test_profile: bool = False) -> dict[str, Any]:
    """Bootstrap текущей сессии; start сам по себе не включает автозапуск."""
    value = create_profile(profile, test_profile=test_profile)
    try:
        enabled = {
            domain: item
            for domain, item in value["agents"].items()
            if not system_disabled(item["label"])
        }
        for domain, item in enabled.items():
            if not job_running(item["label"]):
                target = f"gui/{os.getuid()}/{item['label']}"
                # Штатный SIGTERM завершает runtime с кодом 0. Job может остаться
                # зарегистрированным без PID; повторный bootstrap дал бы EEXIST.
                registered = (
                    run(
                        ["/bin/launchctl", "print", target], check=False
                    ).returncode
                    == 0
                )
                if registered:
                    run(["/bin/launchctl", "kickstart", target])
                else:
                    run(
                        [
                            "/bin/launchctl",
                            "bootstrap",
                            f"gui/{os.getuid()}",
                            str(profile / (domain + ".plist")),
                        ]
                    )
        deadline = time.monotonic() + 10
        while not all(job_running(item["label"]) for item in enabled.values()):
            if time.monotonic() >= deadline:
                raise RuntimeError("Local runtime startup timeout")
            time.sleep(0.1)
        return value
    except BaseException:
        stop(profile)
        raise


def open_guis(profile: Path) -> None:
    """Точный .app и отдельная env каждому GUI; глобальный launchctl setenv не нужен."""
    value = manifest(profile)
    for domain, item in value["agents"].items():
        run(
            [
                "/usr/bin/open",
                "-n",
                "--env",
                domain.upper()
                + "_LOCAL_RUNTIME_CONFIG="
                + item["configuration"],
                item["bundle"],
            ]
        )


def main() -> None:
    """Пользователь явно выбирает запуск/остановку локального профиля."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "start",
            "stop",
            "status",
            "gui",
            "enable-persistence",
            "disable-persistence",
        ],
    )
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--test-profile", action="store_true")
    parser.add_argument(
        "--domain", choices=["ares", "athena", "both"], default="both"
    )
    parser.add_argument("--launch-agents-directory", type=Path)
    args = parser.parse_args()
    profile = args.profile.absolute()
    domains = None if args.domain == "both" else [args.domain]
    if args.launch_agents_directory is not None and args.action not in {
        "enable-persistence",
        "disable-persistence",
        "status",
    }:
        parser.error(
            "--launch-agents-directory is only valid for persistence/status"
        )
    if args.action == "start":
        value = start(profile, test_profile=args.test_profile)
        print(
            json.dumps(
                {
                    "mode": value["mode"],
                    "agents": list(value["agents"]),
                    "started": True,
                }
            )
        )
    elif args.action == "stop":
        print(json.dumps({"stopped": stop(profile)}))
    elif args.action == "gui":
        open_guis(profile)
        print(json.dumps({"opened": list(PRODUCTS)}))
    else:
        operation = {
            "enable-persistence": enable_persistence,
            "disable-persistence": disable_persistence,
            "status": persistence_status,
        }[args.action]
        print(
            json.dumps(
                operation(
                    profile,
                    domains,
                    launch_agents_directory=args.launch_agents_directory,
                    test_profile=args.test_profile,
                )
            )
        )


if __name__ == "__main__":
    main()
