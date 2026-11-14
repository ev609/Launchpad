#!/bin/bash
# Собирает Launchpad.app из SwiftPM-таргета.
# Использование: ./scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Launchpad"
APP_DIR="$ROOT/build/$APP_NAME.app"

# Архитектуры через пробел. Релиз — универсальный (Apple Silicon + Intel),
# отладка — только родная архитектура, чтобы собиралась быстрее.
# Переопределение: ARCHS="arm64" ./scripts/build_app.sh release
if [[ "$CONFIG" == "release" ]]; then
    ARCHS="${ARCHS:-arm64 x86_64}"
else
    ARCHS="${ARCHS:-$(uname -m)}"
fi
MIN_MACOS="13.0"

cd "$ROOT"
SLICES=()
for ARCH in $ARCHS; do
    TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
    echo "==> Сборка ($CONFIG, $ARCH)…"
    # Не фильтруем вывод через `... || true`: иначе ошибка компиляции маскируется,
    # а оставшийся в .build старый бинарник ошибочно попадает в новый релиз.
    swift build -c "$CONFIG" --triple "$TRIPLE"
    SLICE="$ROOT/.build/$TRIPLE/$CONFIG/$APP_NAME"
    [[ -f "$SLICE" ]] || SLICE="$ROOT/.build/$ARCH-apple-macosx/$CONFIG/$APP_NAME"
    if [[ ! -f "$SLICE" ]]; then
        echo "Ошибка: бинарник для $ARCH не найден" >&2
        exit 1
    fi
    SLICES+=("$SLICE")
done

BIN="$ROOT/.build/$APP_NAME-$CONFIG-universal"
rm -f "$BIN"
lipo -create "${SLICES[@]}" -output "$BIN"
echo "==> Архитектуры: $(lipo -archs "$BIN")"

echo "==> Сборка бандла $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Маркетинговая версия (x.y.z) остаётся стабильной и используется updater-ом
# для сравнения с GitHub Releases. Каждая конкретная сборка получает собственные
# номер и UTC-время автоматически, без изменения исходного Info.plist.
BUILD_DATE_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
BUILD_NUMBER="$(date -u '+%Y%m%d.%H%M%S')"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LaunchpadBuildDate string $BUILD_DATE_UTC" \
    "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :LaunchpadBuildDate $BUILD_DATE_UTC" \
        "$APP_DIR/Contents/Info.plist"
echo "==> Версия сборки $BUILD_NUMBER ($BUILD_DATE_UTC)"

# Иконка, если есть.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc подпись, чтобы приложение запускалось без предупреждений Gatekeeper локально.
# Ошибка подписи фатальна: updater проверяет `codesign --verify` и отклонил бы
# такой релиз уже на машинах пользователей.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Готово: $APP_DIR"
echo "    Запуск: open \"$APP_DIR\""
