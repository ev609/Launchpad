#!/bin/bash
# Собирает Launchpad.app из SwiftPM-таргета.
# Использование: ./scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Launchpad"
APP_DIR="$ROOT/build/$APP_NAME.app"

echo "==> Сборка ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -vE "XCTest|PlatformPath|xcrun:" || true

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "Ошибка: бинарник не найден: $BIN" >&2
    exit 1
fi

echo "==> Сборка бандла $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Иконка, если есть.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc подпись, чтобы приложение запускалось без предупреждений Gatekeeper локально.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
    echo "(codesign пропущен)"

echo "==> Готово: $APP_DIR"
echo "    Запуск: open \"$APP_DIR\""
