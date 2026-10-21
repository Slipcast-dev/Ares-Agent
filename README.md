![Ares](assets/ares-banner.png)

<p align="center"><img src="docs/assets/ares-icon.png" width="160" alt="Ares"></p>

# Арес / Ares

[Русский](README.md) · [English](README.en.md)

Арес — отдельный локальный агент macOS. Безопасная работа с файлами, правилами и индексом.

Версия **0.28.0**. Целевая macOS14+, текущий выпуск — **Apple Silicon arm64**.
Запуск на Intel и macOS14 отдельно ещё не принят. Проект с доступными исходниками
использует собственную некоммерческую [лицензию](LICENSE), а не MIT/OSI-лицензию.

[![Version 0.28.0](https://img.shields.io/badge/Version-0.28.0-a65237?style=flat-square)](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.28.0) [![CI](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml)

[DMG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.28.0/Ares-0.28.0-unsigned.dmg) · [PKG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.28.0/Ares-0.28.0-unsigned.pkg) · [SHA256SUMS](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.28.0/SHA256SUMS)

## Установка

PKG/DMG прикладываются к релизу отдельно от исходников. Выпуск **без подписи
Apple Developer ID и без notarization**. Перед использованием сверьте SHA256SUMS.
Локальная ad-hoc подпись защищает целостность, но не подтверждает издателя.
Не отключайте Gatekeeper глобально. Автоматическая установка не выполняется.

## Сборка

Нужны Xcode/Command Line Tools, Swift5.9+ и SDK macOS14+. Общий EcosystemKit
включён в репозиторий: соседние папки не требуются. Yams6.2.2 закреплён lock-файлом.

```sh
python3 scripts/verify_ecosystem_dependency.py
swift test
swift build -c release
scripts/package_app.zsh
```

Приложение появится в `dist/Ares.app`. Технические имена исполняемых файлов
сохранены ради совместимости модулей и клиентских конфигураций.

## Управление и безопасность

Интерфейс и фоновая служба разделены. Доступ к данным по умолчанию запрещён;
разрешения выдаются внутри каждого агента отдельно. Подключение Codex/Harness
выполняется через проверяемый план в интерфейсе. Hermes предусмотрен архитектурой,
но действующее подключение ещё не реализовано. Ключи моделей и личные данные
в комплект не входят.

[Эксплуатация](docs/OPERATIONS.md) · [Архитектура](docs/ARCHITECTURE.md) ·
[Безопасность](SECURITY.md) · [Производительность](docs/PERFORMANCE.md) ·
[Изменения](CHANGELOG.md) · [Поддержка](SUPPORT.md).

## Участие

Прочитайте [CONTRIBUTING](CONTRIBUTING.md), [правила общения](CODE_OF_CONDUCT.md)
и лицензию. Не публикуйте в issue личные файлы, профили и секреты. Сообщения об
уязвимостях направляйте по правилам SECURITY.md.

[Лицензия на русском](LICENSE) · [English license translation](LICENSE.en.md).
