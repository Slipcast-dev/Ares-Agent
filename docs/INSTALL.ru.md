# Установка Ares0.37.0

[Скачать предварительный выпуск](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.37.0).

## Совместимость

Текущие PKG/DMG предназначены для Apple Silicon arm64. Целевая версия macOS14+;
автоматические сборки и тесты опубликованного исходного кода прошли в GitHub CI macOS15. Выполнение на Intel/macOS14 отдельно
ещё не принято.

## Подпись и проверка файла

**Без подписи Apple Developer ID и без нотариализации Apple.** Вложенные локальные
ad-hoc подписи проверены; они подтверждают целостность, но не издателя.
Скачайте SHA256SUMS и сверьте контрольную сумму PKG или DMG. Не отключайте
Gatekeeper глобально ради установки.

## Первый запуск

Установите выбранный комплект, откройте приложение и выдайте доступ только к
нужным данным. Разрешения каждого агента независимы. Подключение Codex/Harness и
автозапуск после входа включаются отдельно в интерфейсе. Сам факт подключения
клиента не разрешает изменение файлов. Системные запросы macOS принимает пользователь.

[Эксплуатация](OPERATIONS.md) · [Обновление](MAINTENANCE.md) · [Удаление](LIFECYCLE.md).

Язык «Системный», «Русский» или «English» выбирается независимо в каждом агенте.
Полная ручная приёмка интерфейса и запуск на macOS14/Intel остаются открытыми.

[PKG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.37.0/Ares-0.37.0-unsigned.pkg) · [DMG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.37.0/Ares-0.37.0-unsigned.dmg) · [SHA256SUMS](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.37.0/SHA256SUMS).

[Status / Статус](STATUS.md).
