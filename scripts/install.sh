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
STAGED="/Applications/Launchpad.app.installing"
BACKUP="/Applications/Launchpad.app.previous"
echo "==> Устанавливаю в $DEST"
rm -rf "$STAGED"
ditto "build/Launchpad.app" "$STAGED"
codesign --verify --deep --strict "$STAGED"

rm -rf "$BACKUP"
if [[ -d "$DEST" ]]; then
    mv "$DEST" "$BACKUP"
fi
if mv "$STAGED" "$DEST"; then
    rm -rf "$BACKUP"
else
    [[ ! -d "$BACKUP" ]] || mv "$BACKUP" "$DEST"
    echo "Ошибка установки; прежняя версия восстановлена." >&2
    exit 1
fi

# Сбрасываем кэш иконок, чтобы новая иконка отобразилась сразу.
touch "$DEST"

echo "==> Готово. Launchpad установлен в /Applications."
echo "    Запустите его из Spotlight/Finder — он появится в строке меню."
