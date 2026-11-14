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

# Релиз сразу уходит всем пользователям через тихое автообновление, а тесты
# локально без Xcode не запускаются. Поэтому выпускаем только коммит, который
# уже лежит на GitHub и прошёл CI. Аварийный обход: LAUNCHPAD_SKIP_CI_CHECK=1.
HEAD_SHA="$(git rev-parse HEAD)"
if [[ "${LAUNCHPAD_SKIP_CI_CHECK:-}" == "1" ]]; then
    echo "ВНИМАНИЕ: проверка CI пропущена (LAUNCHPAD_SKIP_CI_CHECK=1)." >&2
else
    echo "==> Проверка CI для ${HEAD_SHA:0:7}"
    git fetch --quiet origin
    if [[ -z "$(git branch -r --contains "$HEAD_SHA")" ]]; then
        echo "Ошибка: коммит ${HEAD_SHA:0:7} не отправлен на GitHub — сделайте push и дождитесь CI." >&2
        exit 1
    fi
    CI_RESULT="$(gh run list --commit "$HEAD_SHA" --workflow ci.yml --limit 1 \
        --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
    if [[ "$CI_RESULT" != "completed success" ]]; then
        echo "Ошибка: CI для ${HEAD_SHA:0:7} не зелёный (${CI_RESULT:-запусков нет})." >&2
        echo "       Дождитесь успешного прогона: gh run watch" >&2
        exit 1
    fi
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

# Нотаризация — только при подписи Developer ID (LAUNCHPAD_SIGN_IDENTITY) и
# сохранённом профиле notarytool:
#   xcrun notarytool store-credentials launchpad-notary --apple-id … --team-id …
#   LAUNCHPAD_NOTARY_PROFILE=launchpad-notary ./scripts/release.sh x.y.z
# После неё тикет прикрепляется к .app, и zip пересобирается уже с ним.
if [[ -n "${LAUNCHPAD_NOTARY_PROFILE:-}" ]]; then
    [[ -n "${LAUNCHPAD_SIGN_IDENTITY:-}" ]] || {
        echo "Ошибка: нотаризация требует подписи Developer ID (LAUNCHPAD_SIGN_IDENTITY)." >&2
        exit 1
    }
    echo "==> Нотаризация (может занять несколько минут)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$LAUNCHPAD_NOTARY_PROFILE" --wait
    xcrun stapler staple build/Launchpad.app
    rm -f "$ZIP"
    ditto -c -k --keepParent build/Launchpad.app "$ZIP"
fi

# Приватный Ed25519-ключ хранится вне репозитория. Путь можно переопределить
# переменной LAUNCHPAD_UPDATE_PRIVATE_KEY на релизной машине.
KEY="${LAUNCHPAD_UPDATE_PRIVATE_KEY:-$HOME/Library/Application Support/Launchpad/update-signing-key.pem}"
if [[ ! -f "$KEY" ]]; then
    echo "Ошибка: ключ подписи обновлений не найден: $KEY" >&2
    exit 1
fi
EXPECTED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :LaunchpadUpdatePublicKey' Resources/Info.plist)"
ACTUAL_PUBLIC_KEY="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)"
# Ключей может быть несколько через запятую (ротация) — нужен один из них.
[[ ",${EXPECTED_PUBLIC_KEY// /}," == *",$ACTUAL_PUBLIC_KEY,"* ]] || {
    echo "Ошибка: приватный ключ не соответствует публичному ключу приложения." >&2
    exit 1
}
echo "==> Подпись zip (Ed25519)"
openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$ZIP" -out "$SIG"
[[ "$(stat -f %z "$SIG")" == "64" ]] || { echo "Ошибка подписи" >&2; exit 1; }

echo "==> Упаковка DMG (для ручной установки)"
DMG="build/Launchpad-$VERSION.dmg"
# Тот же бандл, что в zip: повторная сборка дала бы другой номер build.
LAUNCHPAD_SKIP_BUILD=1 ./scripts/make_dmg.sh >/dev/null

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
