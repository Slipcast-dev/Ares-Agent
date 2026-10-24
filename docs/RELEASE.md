# Ares 0.38.1 — release information / Информация о выпуске

[Current release / Текущий релиз](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.38.1) · [All releases / Все релизы](https://github.com/Slipcast-dev/Ares-Agent/releases).

## Download / Загрузка

- [PKG installer](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/Ares-0.38.1-unsigned.pkg).
- [DMG image](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/Ares-0.38.1-unsigned.dmg).
- [SHA256SUMS](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.38.1/SHA256SUMS).

Download the installer and SHA256SUMS into one directory. Verify with:

```sh
shasum -a 256 -c SHA256SUMS
```

Скачайте оба формата для этой команды либо оставьте в SHA256SUMS строку
скачанного файла. PKG/DMG содержат одно и то же приложение Ares 0.38.1.
Установщики — Apple Silicon arm64. Минимум macOS 14 указан в bundle;
отдельная приёмка на macOS 14 и Intel остаётся открытой.

## Changes / Изменения

Checked dictionary serialization for default rule/action/condition models; unexpected arrays, scalars, null and encoding failures return operationFailed. Five regression tests cover errors and recovery of the next normalization call.

Рабочие исходники и опубликованные копии явно разделены в документации.
Файловые права, согласия, очереди и автоматизация не расширены.
Для существующего профиля используйте штатное холодное
[обслуживание](MAINTENANCE.md); не удаляйте данные для обхода проверки версии.

## Validation / Проверки

- Full local application suites: Ares 101 tests, Athena 277; one existing accessibility skip each, zero failures.
- Shared EcosystemKit: 299 tests, zero failures, including revocation, destination conflict, cancellation and uncertain-outcome recovery.
- Debug and release builds use the trusted local Xcode/SwiftPM environment.
- Standalone dependency and strict RU/EN gates are checked before publication.
- PKG/DMG extraction, resources, icons and nested signatures are verified for release artifacts.
- [GitHub Actions](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml) reports verification of this exact published commit.

## Limits / Ограничения

Pre-release with local ad-hoc signatures, without Apple Developer ID or notarization.
Системная установка PKG с admin-правами, полная ручная VoiceOver/клавиатурная
приёмка, реальные сон/вход и длительная аппаратная работа не заявляются проверенными.
Do not disable Gatekeeper globally. User profiles, databases, grants and secrets
are excluded from source and installer assets. See [security](../SECURITY.md).
