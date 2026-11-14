#!/bin/bash
# Выпуск релиза в GitHub Releases (для авто-обновления).
# Использование: ./scripts/release.sh 0.2.0
set -euo pipefail

VERSION="${1:?Укажите версию, напр.: ./scripts/release.sh 0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Ошибка: версия должна иметь вид x.y.z" >&2
    exit 1
}
git diff --quiet && git diff --cached --quiet || {
    echo "Ошибка: перед релизом закоммитьте изменения." >&2
    exit 1
}
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Ошибка: тег v$VERSION уже существует." >&2
    exit 1
fi

echo "==> Версия $VERSION в Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist 2>/dev/null || true

echo "==> Сборка иконки и .app"
[ -f Resources/AppIcon.icns ] || ./scripts/make_icon.sh
./scripts/build_app.sh release

echo "==> Упаковка zip (для авто-обновления)"
ZIP="build/Launchpad.zip"
SIG="build/Launchpad.zip.sig"
rm -f "$ZIP"
ditto -c -k --keepParent build/Launchpad.app "$ZIP"

# Приватный Ed25519-ключ хранится вне репозитория. Путь можно переопределить
# переменной LAUNCHPAD_UPDATE_PRIVATE_KEY на релизной машине.
KEY="${LAUNCHPAD_UPDATE_PRIVATE_KEY:-$HOME/Library/Application Support/Launchpad/update-signing-key.pem}"
if [[ ! -f "$KEY" ]]; then
    echo "Ошибка: ключ подписи обновлений не найден: $KEY" >&2
    exit 1
fi
EXPECTED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :LaunchpadUpdatePublicKey' Resources/Info.plist)"
ACTUAL_PUBLIC_KEY="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)"
[[ "$ACTUAL_PUBLIC_KEY" == "$EXPECTED_PUBLIC_KEY" ]] || {
    echo "Ошибка: приватный ключ не соответствует публичному ключу приложения." >&2
    exit 1
}
echo "==> Подпись zip (Ed25519)"
openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$ZIP" -out "$SIG"
[[ "$(stat -f %z "$SIG")" == "64" ]] || { echo "Ошибка подписи" >&2; exit 1; }

echo "==> Упаковка DMG (для ручной установки)"
DMG="build/Launchpad-$VERSION.dmg"
./scripts/make_dmg.sh >/dev/null

echo "==> Коммит версии + тег v$VERSION"
git add Resources/Info.plist
git commit -m "release: v$VERSION"
git tag "v$VERSION"
git push origin HEAD
git push origin "v$VERSION"

echo "==> GitHub Release (zip + подпись + dmg)"
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$SIG" "$DMG" --clobber
else
    gh release create "v$VERSION" "$ZIP" "$SIG" "$DMG" --title "v$VERSION" --notes "Launchpad v$VERSION"
fi

echo "==> Готово: релиз v$VERSION. Клиенты обновятся при следующей проверке."
