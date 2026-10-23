"""Контракт macOS metadata и локализованных текстов unsigned установщика."""
from __future__ import annotations

from pathlib import Path
import plistlib
from typing import Any

BRANDS = {'Ares': 'Арес', 'Athena': 'Афина'}
# Имена файлов, bundle IDs и executable не выводятся из перевода: это identity.
BUNDLE_IDS = {'Ares': 'dev.slipcast.fileorganizer', 'Athena': 'com.macassistant.app'}


def validate_metadata(app: Path, name: str) -> dict[str, Any]:
    """Проверяем закрытый набор ключей: таблица не может добавить privacy purpose."""
    russian = BRANDS[name]
    bundles = (app, app / 'Contents/Library/LoginItems' / (name + 'Background.app'))
    for index, bundle in enumerate(bundles):
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        expected_id = BUNDLE_IDS[name] + ('.background' if index else '')
        if info.get('CFBundleIdentifier') != expected_id:
            raise RuntimeError('Localized metadata changed bundle identity')
        if info.get('CFBundleDevelopmentRegion') != 'en' or set(info.get('CFBundleLocalizations', [])) != {'ru', 'en'}:
            raise RuntimeError('Missing supported macOS locales')
        for language in ('ru', 'en'):
            path = bundle / 'Contents/Resources' / (language + '.lproj/InfoPlist.strings')
            values = plistlib.loads(path.read_bytes())
            expected = (russian + (' — фоновая служба' if index else '')) if language == 'ru' else name + (' Background' if index else '')
            if values != {'CFBundleName': expected, 'CFBundleDisplayName': expected}:
                raise RuntimeError('Unexpected localized metadata keys or names')
        if any(key.startswith('NS') and key.endswith('UsageDescription') for key in info):
            # В исходных приложениях таких purpose strings не было. Новое право
            # не должно появиться побочным результатом локализации.
            raise RuntimeError('Unexpected privacy purpose key in localization stage')
    return {'supportedLocales': ['ru', 'en'], 'localizedBundles': 2,
            'localizedMetadataKeys': ['CFBundleName', 'CFBundleDisplayName'],
            'newPrivacyPermissions': False}


def write_installer_resources(directory: Path, name: str, version: str) -> dict[str, bytes]:
    """Статические HTML не содержат script/сетевых ссылок или личных данных."""
    resources: dict[str, bytes] = {}
    russian = BRANDS[name]
    bodies = {
        'ru': (f'{russian} {version}',
               'Локальная проверочная сборка. Без подписи Apple Developer ID и нотариального заверения Apple.',
               'Установщик копирует приложение в /Applications. Фоновые службы не включаются установщиком. Откройте приложение для запуска службы; доступ к папкам и клиентам выдаётся отдельно в приложении.',
               'Язык интерфейса выбирается в настройках агента. Названия в Finder и системных диалогах выбирает macOS. Данные и разрешения другого агента не объединяются.',
               'Перед обновлением остановите выполняющиеся задачи и сохраните резервную копию данных. Инструкции: Contents/Resources/ProfileMaintenance.md и ProfileLifecycle.md внутри приложения. Удаление приложения не должно удалять личный профиль.'),
        'en': (f'{name} {version}',
               'Local preview. No Apple Developer ID signature or Apple notarization.',
               'The installer copies the application to /Applications. The installer does not activate background services. Open the application to start its service; folder and client access must be granted separately in the application.',
               'Choose the interface language in the agent settings. macOS chooses names shown in Finder and system dialogs. Each agent keeps separate data and permissions.',
               'Before upgrading, stop running tasks and back up your data. See Contents/Resources/ProfileMaintenance.md and ProfileLifecycle.md inside the application. Removing the application should preserve your personal profile.'),
    }
    for language, paragraphs in bodies.items():
        for filename, content in (('Welcome.html', paragraphs[:3]), ('ReadMe.html', (paragraphs[0], *paragraphs[3:]))):
            html = ('<!doctype html><html lang="' + language + '"><meta charset="utf-8"><title>'
                    + paragraphs[0] + '</title><body><h1>' + content[0] + '</h1>'
                    + ''.join('<p>' + paragraph + '</p>' for paragraph in content[1:]) + '</body></html>\n')
            relative = language + '.lproj/' + filename
            data = html.encode('utf-8')
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            resources[relative] = data
    return resources


def verify_installer_resources(expanded: Path, expected: dict[str, bytes]) -> None:
    """Ищем ресурсы реально собранного product archive, а не исходный staging."""
    for relative, data in expected.items():
        matches = [path for path in expanded.rglob(Path(relative).name)
                   if path.parent.name == Path(relative).parent.name and path.read_bytes() == data]
        if len(matches) != 1:
            raise RuntimeError('Missing or ambiguous localized installer resource: ' + relative)
