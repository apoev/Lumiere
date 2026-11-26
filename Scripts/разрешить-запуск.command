#!/bin/bash
# Снять карантин Gatekeeper и подписать Lumiere.app рядом с этим скриптом.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Lumiere.app"

if [[ ! -d "$APP" ]]; then
  echo "Не найден Lumiere.app в папке:"
  echo "  $DIR"
  read -r -p "Enter…" _
  exit 1
fi

echo "Снимаю карантин…"
xattr -cr "$APP" 2>/dev/null || true
echo "Подписываю…"
codesign --force --sign - --deep "$APP" 2>/dev/null || true
echo "Готово: $APP"
open "$APP"
