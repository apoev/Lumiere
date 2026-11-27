#!/bin/bash
# Собирает Lumiere и публикует zip на GitHub Releases.
# Родственники получают его через «Проверить обновления» в самом приложении.
# Тот же скрипт запускает GitHub Actions после пуша в main.
# Заметки к релизу можно передать аргументами: ./Scripts/release.sh "Что нового"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="${GITHUB_REPOSITORY:-apoev/Lumiere}"

# Теги нужны, чтобы номер не повторил уже опубликованный релиз.
git fetch --tags --force origin >/dev/null 2>&1 || true

"$ROOT/Scripts/build.sh"

APP="$ROOT/build/Lumiere.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Lumiere-$VERSION.zip"
TAG="v$VERSION"
NOTES_FILE="$ROOT/build/release-notes.txt"

if [[ $# -gt 0 ]]; then
  NOTES="$*"
else
  PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -n "$PREV" ]]; then
    CHANGES="$(git log --pretty='- %s' "${PREV}..HEAD")"
  else
    CHANGES="$(git log -1 --pretty=%s)"
  fi
  NOTES="Обновление Lumiere ${VERSION}."
  if [[ -n "${CHANGES//[[:space:]]/}" ]]; then
    NOTES="${NOTES}"$'\n\n'"${CHANGES}"
  fi
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
printf '%s\n' "$NOTES" > "$NOTES_FILE"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Релиз $TAG уже есть. Новый номер появится при следующей сборке."
  exit 1
fi

gh release create "$TAG" "$ZIP" \
  --repo "$REPO" \
  --title "Lumiere $VERSION" \
  --notes-file "$NOTES_FILE"

echo "Опубликовано: https://github.com/$REPO/releases/tag/$TAG"
