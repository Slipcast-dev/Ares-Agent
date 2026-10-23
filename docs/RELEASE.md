# Ares 0.38.0 — release information / Информация о выпуске

[Current release / Текущий релиз](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.38.0) · [All releases / Все релизы](https://github.com/Slipcast-dev/Ares-Agent/releases).

## Download / Загрузка

- [PKG installer](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.0/Ares-0.38.0-unsigned.pkg).
- [DMG image](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.0/Ares-0.38.0-unsigned.dmg).
- [SHA256SUMS](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.0/SHA256SUMS).

Download the installer and SHA256SUMS into one directory. Verify with:

```sh
shasum -a 256 -c SHA256SUMS
```

Скачайте оба формата для этой команды либо оставьте в SHA256SUMS строку
скачанного файла. PKG/DMG содержат одно и то же приложение Ares 0.38.0.
Установщики — Apple Silicon arm64. Минимум macOS 14 указан в bundle;
отдельная приёмка на macOS 14 и Intel остаётся открытой.

## Changes / Изменения

- Coordinated 0.38.0 application, background runtime and installer metadata.
- Current RU/EN interface, safe file indexing, search, duplicate analysis and approved rules.
- Independent standalone source builds with a vendored, SHA-256-locked EcosystemKit.

Shared fix: external MCP helpers now receive both shared resource bundles during
standalone profile creation and cold upgrade. Upgrade and rollback treat these
resources as code and preserve user state. GUI, runtime and MCP identities remain separate.

Общее исправление: при создании и обновлении самостоятельного профиля переносятся
ресурсы локализации MCP. Сохранены очереди, история, разрешения и настройки.
Для существующего профиля используйте штатный холодный протокол
[обслуживания](MAINTENANCE.md), [установки и переноса](LIFECYCLE.md).
Не заменяйте содержимое рабочей базы вручную.

## Validation / Проверки

- Local full application suite: 85 tests, zero failures.
- Shared installation/maintenance regression suite: 24 tests, zero failures.
- Standalone dependency and strict RU/EN localization checks: passed.
- Standalone release build: passed.
- PKG extraction and read-only DMG checks, icons, resources and nested signatures: passed.
- Installed MCP initialization/capabilities: passed for Codex and DeepSeek Harness.
- Existing stopped Ares runtime was left stopped; running-service acceptance is not claimed.

[GitHub Actions](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml) provides the current server-side
result. Workflow runners and local measurements describe different environments;
a successful build is not full hardware acceptance.

## Limits / Ограничения

Pre-release with local ad-hoc signatures, without Apple Developer ID or notarization.
Системная установка PKG с admin-правами, полная ручная VoiceOver/клавиатурная
приёмка, реальные сон/вход и длительная аппаратная работа не заявляются проверенными.
Do not disable Gatekeeper globally. User profiles, databases, grants and secrets
are excluded from source and installer assets. See [security](../SECURITY.md).
