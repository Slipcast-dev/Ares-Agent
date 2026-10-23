# Арес / Ares — статус / status

Проверено 23 октября 2026. / Reviewed 23 October 2026.

| Параметр / Item | Актуальное значение / Current value |
|---|---|
| Приложение / App | [0.37.0 prerelease](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.37.0) |
| Общий пакет / Shared package | EcosystemKit 0.29.0; vendored and SHA-256 locked |
| Установщики / Installers | Apple Silicon arm64; PKG + DMG + SHA256SUMS |
| Целевая ОС / OS target | macOS 14+ |
| Автоматические проверки / Automation | macOS 15 GitHub CI; local regression evidence is documented separately |
| Локализация / Language | Independent System / Русский / English |
| Подпись / Signing | Local ad-hoc only; no Apple Developer ID; not notarized |
| Лицензия / License | Custom non-commercial, source-available; not MIT/OSI |
| Клиенты / Clients | Codex and DeepSeek Harness; explicit setup and data grants |
| Hermes | Future integration; no live connection |

## Приёмка / Acceptance

Полная ручная VoiceOver/клавиатура/focus/clipping, реальный сон/вход,проверки
установленных клиентов и длительная аппаратная работа остаются открытыми.
Native macOS 14/Intel execution and complete manual accessibility,real sleep/login,
installed-client and long-duration hardware acceptance remain open.
Intel cross-compilation is build evidence; shipped installers are arm64.
No battery-saving percentage or complete production-readiness claim is made.

[CI runs](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml)
show the result for each source commit. Passing CI does not close manual gates.
App release 0.37.0 and Kit 0.29.0 have independent version sequences. Historical
changelog entries and0.28.0 measurements describe their named releases.

[Установка RU](INSTALL.ru.md) · [Installation EN](INSTALL.en.md) ·
[Security](../SECURITY.md) · [Changes](../CHANGELOG.md).
