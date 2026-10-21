#!/bin/zsh
set -euo pipefail

# Скрипт формирует локальный .app из SPM-исполняемого файла. Он не публикует
# артефакт, не ищет сертификаты и не отправляет его на notarization.
ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_DIR="$OUTPUT_DIR/Ares.app"
# Bundle сначала собирается отдельно: Finder не должен увидеть приложение
# без Info.plist или иконки в промежутке между удалением и копированием.
mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.ares-package.XXXXXX")"
STAGED_APP="$STAGING_DIR/Ares.app"
CONTENTS="$STAGED_APP/Contents"
ICONSET="$STAGING_DIR/AppIcon.iconset"
# Удаляется только уникальный staging-каталог данной сборки.
trap 'rm -rf "$STAGING_DIR"' EXIT

cd "$ROOT_DIR"
python3 "$ROOT_DIR/scripts/verify_ecosystem_dependency.py"
swift build -c release --product FileOrganizer
swift build -c release --product FileOrganizerMCP
swift build -c release --product FileOrganizerRulesWorker
swift build -c release --product AresRuntime
swift build -c release --product AresMaintenance
BUILD_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$ICONSET"
cp "$BUILD_DIR/AresMaintenance" "$CONTENTS/MacOS/AresMaintenance"
cp "$BUILD_DIR/FileOrganizer" "$CONTENTS/MacOS/FileOrganizer"
cp "$BUILD_DIR/FileOrganizerMCP" "$CONTENTS/MacOS/FileOrganizerMCP"
cp "$BUILD_DIR/FileOrganizerRulesWorker" "$CONTENTS/MacOS/FileOrganizerRulesWorker"
cp "$ROOT_DIR/docs/MAINTENANCE.md" "$CONTENTS/Resources/ProfileMaintenance.md"
cp "$ROOT_DIR/docs/LIFECYCLE.md" "$CONTENTS/Resources/ProfileLifecycle.md"
cp "$ROOT_DIR/distribution/Info.plist" "$CONTENTS/Info.plist"
# Новый номер сборки помогает LaunchServices отличать обновление от прежнего
# bundle. Публичная версия продукта и bundle identifier остаются прежними.
PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo 2)"
if [[ "$PREVIOUS_BUILD" != <-> ]]; then
  PREVIOUS_BUILD=2
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((PREVIOUS_BUILD + 1))" "$CONTENTS/Info.plist"

# SwiftPM хранит обработанные ресурсы отдельно от бинарника. `Bundle.module`
# ищет именно этот bundle внутри .app, поэтому он обязателен для запуска UI.
RESOURCE_BUNDLE="$BUILD_DIR/FileOrganizer_FileOrganizer.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Не найден ресурсный bundle SwiftPM: $RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
# Роли/схемы общего пакета должны находиться и в установленном приложении,
# а не случайно читаться из .build на машине разработчика.
CONTRACT_BUNDLE="$BUILD_DIR/EcosystemKit_EcosystemContracts.bundle"
if [[ ! -d "$CONTRACT_BUNDLE" ]]; then
  echo "Не найден ресурсный bundle EcosystemContracts" >&2
  exit 1
fi
cp -R "$CONTRACT_BUNDLE" "$CONTENTS/Resources/"

# Runtime должен перемещаться вместе с приложением. Вложенный .app не регистрирует
# службу и не включает автозапуск: activation/grants остаются явным решением.
BACKGROUND="$CONTENTS/Library/LoginItems/AresBackground.app"
mkdir -p "$BACKGROUND/Contents/MacOS" "$BACKGROUND/Contents/Resources"
cp "$BUILD_DIR/AresRuntime" "$BACKGROUND/Contents/MacOS/AresRuntime"
cp -R "$CONTRACT_BUNDLE" "$BACKGROUND/Contents/Resources/"
python3 - "$BACKGROUND/Contents/Info.plist" "${ECOSYSTEM_APP_VERSION:-0.28.0}" <<'PLIST'
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'AresRuntime',
    'CFBundleIdentifier': 'dev.slipcast.fileorganizer.background',
    'CFBundleName': 'Ares Background', 'CFBundleVersion': sys.argv[2],
    'CFBundleShortVersionString': sys.argv[2],
    'CFBundleIconFile': 'FileOrganizerAres.icns',
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication'}))
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${ECOSYSTEM_APP_VERSION:-0.28.0}" "$CONTENTS/Info.plist"

# `sips` создаёт обязательные размеры из исходного изображения Ареса; исходник
# не меняется, поэтому приложение и репозиторий используют один визуальный образ.
SOURCE_ICON="$ROOT_DIR/Sources/FileOrganizer/Resources/AresAppIcon.png"
sizes=(16 32 32 64 128 256 256 512 512 1024)
names=(icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png icon_512x512.png icon_512x512@2x.png)
for index in {1..${#sizes}}; do
  sips -z "${sizes[$index]}" "${sizes[$index]}" "$SOURCE_ICON" --out "$ICONSET/${names[$index]}" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
cp "$CONTENTS/Resources/AppIcon.icns" "$CONTENTS/Resources/FileOrganizerAres.icns"
# Уведомления отправляет вложенный runtime с собственным bundle ID.
# macOS читает его ресурсы: иконка только внешнего GUI здесь не наследуется.
cp "$CONTENTS/Resources/FileOrganizerAres.icns" "$BACKGROUND/Contents/Resources/FileOrganizerAres.icns"
rm -rf "$ICONSET"

# Подпись выполняется после добавления ресурсов: подпись бинарника SwiftPM
# сама по себе не описывает готовый bundle. Helper подписывается первым.
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$CONTENTS/MacOS/AresMaintenance"
  codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$BACKGROUND"
  codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$CONTENTS/MacOS/FileOrganizerMCP"
  codesign --force --options runtime --sign "$DEVELOPER_ID_IDENTITY" "$CONTENTS/MacOS/FileOrganizerRulesWorker"
  codesign --force --options runtime --entitlements "$ROOT_DIR/distribution/FileOrganizer.entitlements" --sign "$DEVELOPER_ID_IDENTITY" "$STAGED_APP"
else
  # Ad-hoc подпись обеспечивает целостность локальной сборки без сертификата
  # разработчика; она не заменяет Developer ID для распространения.
  codesign --force --sign - "$CONTENTS/MacOS/AresMaintenance"
  codesign --force --sign - "$BACKGROUND"
  codesign --force --sign - "$CONTENTS/MacOS/FileOrganizerMCP"
  codesign --force --sign - "$CONTENTS/MacOS/FileOrganizerRulesWorker"
  codesign --force --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
plutil -lint "$CONTENTS/Info.plist"
# Сохраняем inode самой папки Ares.app. rsync обновляет её содержимое и убирает
# устаревшие ресурсы только внутри известного выходного bundle, не затрагивая
# соседние приложения. Иконка существует до публикации обновлённого Info.plist.
mkdir -p "$APP_DIR"
/usr/bin/rsync -a --delete "$STAGED_APP/" "$APP_DIR/"
codesign --verify --deep --strict "$APP_DIR"
/usr/bin/touch "$APP_DIR"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${ECOSYSTEM_SKIP_LSREGISTER:-0}" != "1" ]] && ! "$LSREGISTER" -f "$APP_DIR"; then
  echo "Предупреждение: LaunchServices не обновил регистрацию Ares; повторно откройте папку dist." >&2
fi
echo "Создано: $APP_DIR"
