#!/bin/bash
# Собирает Launchpad.app и упаковывает в DMG для ручной установки
# (перетащить в Applications). Использование: ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Иконка + сборка бандла.
[ -f Resources/AppIcon.icns ] || ./scripts/make_icon.sh
./scripts/build_app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="build/Launchpad-$VERSION.dmg"

echo "==> Готовлю содержимое DMG"
STAGE="$(mktemp -d)"
cp -R "build/Launchpad.app" "$STAGE/Launchpad.app"
ln -s /Applications "$STAGE/Applications"      # для drag-and-drop установки

echo "==> Создаю $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Launchpad" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Готово: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Установка: открыть DMG → перетащить Launchpad в Applications."
