#!/bin/bash
# Выпуск релиза в GitHub Releases (для авто-обновления).
# Использование: ./scripts/release.sh 0.2.0
set -euo pipefail

VERSION="${1:?Укажите версию, напр.: ./scripts/release.sh 0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Версия $VERSION в Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist 2>/dev/null || true

echo "==> Сборка иконки и .app"
[ -f Resources/AppIcon.icns ] || ./scripts/make_icon.sh
./scripts/build_app.sh release

echo "==> Упаковка zip (для авто-обновления)"
ZIP="build/Launchpad.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Launchpad.app "$ZIP"

echo "==> Упаковка DMG (для ручной установки)"
DMG="build/Launchpad-$VERSION.dmg"
./scripts/make_dmg.sh >/dev/null

echo "==> Коммит версии + тег v$VERSION"
git add Resources/Info.plist
git commit -m "release: v$VERSION" 2>/dev/null || echo "(нет изменений для коммита)"
git tag "v$VERSION" 2>/dev/null || echo "(тег уже есть)"
git push origin HEAD 2>/dev/null || echo "(git push HEAD пропущен)"
git push origin "v$VERSION" 2>/dev/null || echo "(git push тега пропущен)"

echo "==> GitHub Release (zip + dmg)"
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$DMG" --clobber
else
    gh release create "v$VERSION" "$ZIP" "$DMG" --title "v$VERSION" --notes "Launchpad v$VERSION"
fi

echo "==> Готово: релиз v$VERSION. Клиенты обновятся при следующей проверке."
