![Ares — Files. Rules. Control.](assets/ares-banner.png)

<p align="center"><strong>Файлы под вашим контролем</strong><br>Папки, индекс файлов, дубликаты и правила автоматизации.</p>
<p align="center"><strong>Русский</strong> · <a href="README.en.md">English</a></p>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-a65237?style=flat-square)](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-414b60?style=flat-square)](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-f06438?style=flat-square)](Package.swift)
[![CI](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml/badge.svg)](https://github.com/Slipcast-dev/Ares-Agent/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Non--commercial-686b73?style=flat-square)](LICENSE)

Ares — отдельный нативный агент для macOS. Он выполняет разрешённые локальные
операции самостоятельно, а Codex и DeepSeek Harness подключаются через MCP
и могут делегировать работу отдельному специалисту. Данные, очередь и разрешения
остаются у этого агента. Для сборки второй проект не требуется.

> **Промежуточная версия E10 · Без подписи разработчика Developer ID.**
> PKG и DMG не имеют подписи Developer ID и не нотариализованы Apple.
> Внутренние executable имеют только локальную ad-hoc подпись.
> Это проверяемый промежуточный выпуск, а не окончательный публичный релиз.

[**Скачать DMG**](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.12.0-intermediate/Ares-E10-arm64-local.dmg) · [Скачать PKG](https://github.com/Slipcast-dev/Ares-Agent/releases/download/v0.12.0-intermediate/Ares-E10-arm64-local.pkg) · [Все файлы выпуска](https://github.com/Slipcast-dev/Ares-Agent/releases/tag/v0.12.0-intermediate)

## Возможности

| Раздел | Возможности |
|---|---|
| Папки | Явный выбор корней, bookmarks, отдельные права клиентов |
| Индекс | Устойчивые снимки, версии файлов, поиск и страницы результатов |
| Дубликаты | SHA-256 в пределах разрешённого доступа, отмена и лимиты |
| Правила | Предпросмотр и подтверждение; теги, ZIP, копии, уведомления, история |
| Фон | Файловые события, расписания, очередь и восстановление после сбоя |

Общий EcosystemKit 0.12.0 находится в `Packages/EcosystemKit`.
Каталог MCP содержит 32 команды; наличие команды не выдаёт доступ к данным.
Права клиентам выдаются отдельно через GUI. Подключение сохраняет выбранную
модель и провайдера клиента. Интерфейс текущего приложения — на русском языке.

## Установка

1. Нужны **Mac с Apple Silicon**, macOS 14+ и Python 3 для промежуточного launcher.
2. Скачайте **DMG** из Releases, откройте образ, затем pkg внутри него.
3. Установите `Ares Intermediate.app` в `/Applications` и откройте приложение.
4. Подтвердите необходимые права в GUI. Автозапуск при входе включается отдельно.

Иконка pkg и значок диска сохраняются внутри DMG после скачивания. Внешняя
пользовательская иконка одиночного pkg/DMG зависит от метаданных Finder и
при прямой загрузке файла не переносится. Контрольные суммы — в `SHA256SUMS.txt`.

macOS может заблокировать неподписанный выпуск. Не отключайте Gatekeeper или TCC.
Подробнее: [установка и ограничения](docs/INSTALL.ru.md).

## Codex и DeepSeek Harness

В настройках подключите нужного клиента: сначала просмотрите план, затем подтвердите
его применение. Выдача прав на данные — отдельное действие. Начните новый чат клиента.
Harness проверен на версии **0.2.0-rc.2**; другие версии требуют проверки совместимости.
Hermes пока не подключён. Если эта же роль уже настроена на другую установку агента,
не перезаписывайте её вслепую: используйте штатное отключение/переподключение.

## Сборка и участие

```sh
swift build
swift test
swift test --package-path Packages/EcosystemKit
python3 scripts/verify_snapshot.py
python3 scripts/build_snapshot.py --configuration release
```

Для первой сборки нужны Xcode/Command Line Tools, Python 3 и доступ к закреплённому
Yams 6.2.2. Публичный CI проверяет сборку и тесты; live-тесты клиентов требуют
установленных клиентов и отдельно разрешённых тестовых профилей.

[Архитектура и проверка](docs/DEVELOPMENT.ru.md) · [Вклад в проект](CONTRIBUTING.md) ·
[Правила общения](CODE_OF_CONDUCT.md) · [Безопасность](SECURITY.md)

## Статус выпуска

Остаются открытыми Developer ID/notarization, реальная установка/обновление на чистом
Mac, проверка macOS 14 на отдельном хосте, Intel, реальные sleep/logout/login,
видимый баннер уведомления и 24-часовой прогон. Установщик не импортирует личные
данные и не регистрирует клиентов автоматически.

## Лицензия

Copyright © 2026 Slipcast-dev. [Публичное некоммерческое использование](LICENSE).
Коммерческое использование, перепубликация и производные версии требуют письменного
разрешения правообладателя. Это не лицензия MIT и не разрешение на свободное
распространение. [English translation](LICENSE.en.md).
[Условия сторонних компонентов](THIRD_PARTY_NOTICES.md).
