#!/bin/bash
# Генерирует Resources/AppIcon.icns из нарисованного мастер-PNG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/build/icon_master.png"
ICONSET="$ROOT/build/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

mkdir -p "$ROOT/build"
echo "==> Рисую мастер-иконку 1024×1024"
swift "$ROOT/scripts/make_icon.swift" "$MASTER"

echo "==> Собираю .iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
declare -a sizes=(16 32 128 256 512)
for s in "${sizes[@]}"; do
    s2=$((s * 2))
    sips -z "$s"  "$s"  "$MASTER" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
    sips -z "$s2" "$s2" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
done

echo "==> iconutil → $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Готово: $OUT"
