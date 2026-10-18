# Разработка Ares

[English](DEVELOPMENT.en.md) · [Главная](../README.md)

- Swift 5.9+, SwiftUI/AppKit, MVVM и Service Layer; actors/async-await.
- Core владеет бизнес-логикой. GUI, runtime и stdio MCP — отдельные executable.
- SQLite WAL, single owner, leases/fencing, cancellation и idempotency защищают
  устойчивые задачи. XPC проверяет UID/CDHash, а не заявленный clientId.
- Codex/Harness имеют отдельные endpoints и grants. Данные default-deny.
- Inbox сохраняет независимую доставку, глобальный processing claim и ключ эффекта.
- Общий EcosystemKit локален и закреплён хешами snapshot.json. Другой проект не нужен.

`swift build`, `swift test`, `swift test --package-path Packages/EcosystemKit`
и `python3 scripts/verify_snapshot.py` — основные проверки. После осознанного
изменения общего пакета проверьте diff и выполните `verify_snapshot.py --refresh`.
Скрипты Python типизированы; нетривиальные решения комментируются на русском.
Секреты в Keychain/среде, не в коде, Git или логах.

Локальный базовый снимок прошёл 64 доменных и 180 общих XCTest.
Hosted CI может пропускать проверки реального Codex CLI при его отсутствии;
он не подменяет живую приёмку клиентов, TCC, сна и уведомлений.

Упаковка: `python3 scripts/build_snapshot.py --configuration release` создаёт
app, pkg и dmg. Пересборка DMG из готового pkg: `python3 scripts/package_distribution.py`.
При отдельном изменении LICENSE используйте `--update-license`, чтобы перепаковать
app и заново создать локальную подпись. Для Developer ID нужен отдельный этап.

Будущие работы: расширяемый адаптер Hermes, финальный UX, нативный подписанный
bootstrap, согласованные миграции, чистая установка/upgrade и release gates.

Исправления переносимости CI: обычное имя файла @main у MCP Ареса;
оба расположения ресурсов SwiftPM; два регрессионных теста.
