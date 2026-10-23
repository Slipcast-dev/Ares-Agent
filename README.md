![Ares](docs/assets/banner.svg)

<p align="center"><img src="docs/assets/ares-icon.png" width="160" alt="Ares"></p>

# Арес / Ares

[Русский](README.md) · [English](README.en.md)

Арес — отдельный локальный агент macOS. Безопасная работа с файлами, правилами и индексом.

Версия **0.37.0**. Целевая macOS14+, текущий выпуск — **Apple Silicon arm64**.
Запуск на Intel и macOS14 отдельно ещё не принят. Проект с доступными исходниками
использует собственную некоммерческую [лицензию](LICENSE), а не MIT/OSI-лицензию.

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


## RU/EN localization / Локализация

Предварительный выпуск **0.37.0**. Выберите «Системный», «Русский» или «English»
в настройках агента. Язык каждого приложения задаётся отдельно. Числа и даты
следуют региону macOS; пользовательские имена, пути и свободный текст истории
сохраняются. Системные настройки используют язык macOS.

Полная ручная проверка VoiceOver/клавиатуры, macOS 14/Intel и установленных
клиентов остаётся открытой. Этот предварительный выпуск не прошёл полную приёмку.

```sh
python3 scripts/verify_localization_acceptance.py --ares-dir . --kit-dir Packages/EcosystemKit --require-reviewed-boundaries --output localization-acceptance.json
ECOSYSTEM_SKIP_LSREGISTER=1 ECOSYSTEM_APP_VERSION=0.37.0 scripts/package_app.zsh
python3 scripts/prepare_local_release.py --run --version 0.37.0 --agent Ares --use-prepared-apps --apps-dir dist --output installers/0.37.0
```

Installer output is unsigned Developer ID and not notarized. These commands
create and verify artifacts; they do not install applications or publish them.
