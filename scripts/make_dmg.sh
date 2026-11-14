#!/bin/bash
# Собирает Launchpad.app и упаковывает в DMG для ручной установки
# (перетащить в Applications). Использование: ./scripts/make_dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Иконка + сборка бандла. LAUNCHPAD_SKIP_BUILD=1 — упаковать уже собранный
# build/Launchpad.app (так release.sh кладёт в DMG ту же сборку, что и в zip).
if [[ "${LAUNCHPAD_SKIP_BUILD:-}" == "1" && -d build/Launchpad.app ]]; then
    echo "==> Использую готовый build/Launchpad.app"
else
    [ -f Resources/AppIcon.icns ] || ./scripts/make_icon.sh
    ./scripts/build_app.sh release
fi

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
