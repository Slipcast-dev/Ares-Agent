# Changes / Изменения

## 0.38.1 — 2026-10-24

- Checked MCP model serialization replaces forced dictionary casts in Ares.
- Five regression cases cover object defaults, arrays/scalars/null, encoder failure and a subsequent successful call.
- Application/MCP release versions and installer links are aligned.
- Current documentation identifies working sources separately from published snapshots and archived stages.
- File automation permissions and behavior are unchanged. Manual hardware/accessibility gates remain open.

## 0.38.0 — 2026-10-23, pre-release

- Coordinated 0.38.0 application, background runtime and installer metadata.
- Current RU/EN interface, safe file indexing, search, duplicate analysis and approved rules.
- Independent standalone source builds with a vendored, SHA-256-locked EcosystemKit.
- Fixed standalone MCP localization resources during profile creation and cold upgrade.
- Added regression coverage for legacy upgrade, resource transfer and rollback.
- Refreshed release downloads, installation instructions and current validation details.
- arm64, local ad-hoc signatures; Developer ID/notarization and external acceptance remain open.

## Previous releases / Предыдущие выпуски

## 0.37.0 — RU/EN prerelease / предварительный выпуск

- Independent System/Russian/English preference per agent.
- RU/EN UI, typed errors, new diagnostic presentation and bilingual MCP metadata.
- Localized GUI/background bundle names and unsigned PKG welcome/readme pages.
- Existing histories, permissions, machine schemas and replay protection retained.
- Full manual accessibility, macOS14/Intel and installed-client acceptance remain open.
- Preliminary release; full production acceptance remains open.

Локализация: независимый выбор System/RU/EN, перевод интерфейса и встроенных
ошибок, локализованные имена GUI/фоновой службы и страницы установщика.
Существующие данные, разрешения и защита от повторных операций сохраняются.

## 0.29.0

Согласованный комплект0.29.0. Поведение runtime Ареса и EcosystemKit0.23.0 сохранено; исправление backlog мониторинга относится к Афине.

Aligned0.29.0 distribution. Ares runtime behavior and EcosystemKit0.23.0 are unchanged; the monitor-backlog fix applies to Athena.

Developer ID unsigned / not notarized.

## После 0.28.0 / After 0.28.0

Source compatibility: SwiftPM resource layouts across Xcode versions; explicit MCP entry filename for older Swift. Released 0.28.0 installer assets remain unchanged.

Совместимость исходников: расположение SwiftPM-ресурсов и точка входа MCP при разных версиях Swift. Установщики релиза 0.28.0 сохранены без замены.

## 0.28.0

- Bounded rule-history paging with scoped cursors.
- Conservative heavy-task concurrency on battery/Low Power/thermal constraints.
- Measured synthetic idle-runtime CPU, memory and kernel wakeups.
- Previous adaptive queues, bounded storage selection and snapshot views retained.
- Standalone source export; Developer ID/notarization remain unavailable.
