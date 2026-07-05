#!/bin/bash
# Собирает иконку + .app и устанавливает Launchpad в /Applications,
# чтобы приложение появилось в системе (Spotlight, Finder, самом Launchpad).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Иконка (если ещё не собрана).
if [[ ! -f "Resources/AppIcon.icns" ]]; then
    echo "==> Генерирую иконку…"
    ./scripts/make_icon.sh
fi

# 2. Сборка .app с иконкой.
./scripts/build_app.sh release

# 3. Установка в /Applications.
DEST="/Applications/Launchpad.app"
echo "==> Устанавливаю в $DEST"
rm -rf "$DEST"
cp -R "build/Launchpad.app" "$DEST"
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

# Сбрасываем кэш иконок, чтобы новая иконка отобразилась сразу.
touch "$DEST"

echo "==> Готово. Launchpad установлен в /Applications."
echo "    Запустите его из Spotlight/Finder — он появится в строке меню."
