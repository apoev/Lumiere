#!/bin/bash
# Собирает Lumiere и публикует zip на GitHub Releases.
# Родственники получают его через «Проверить обновления» в самом приложении.
# Заметки к релизу можно передать аргументами: ./Scripts/release.sh "Что нового"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/Scripts/build.sh"

APP="$ROOT/build/Lumiere.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Lumiere-$VERSION.zip"
TAG="v$VERSION"
NOTES="${*:-Обновление Lumiere $VERSION.}"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if gh release view "$TAG" --repo apoev/Lumiere >/dev/null 2>&1; then
  echo "Релиз $TAG уже есть. Новый номер появится при следующей сборке."
  exit 1
fi

gh release create "$TAG" "$ZIP" \
  --repo apoev/Lumiere \
  --title "Lumiere $VERSION" \
  --notes "$NOTES"

echo "Опубликовано: https://github.com/apoev/Lumiere/releases/tag/$TAG"
