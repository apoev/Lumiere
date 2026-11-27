#!/bin/bash
# Сборка Lumiere.app через swiftc — тот же путь, что у Mimir.
# Xcode.app на этой машине не обязателен. project.yml нужен, если позже поставить Xcode и xcodegen.
# libvlc берётся из установленного VLC.app, кодеки в бандл не копируются.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macosx14.0"
APP="$ROOT/build/Lumiere.app"
BIN="$APP/Contents/MacOS/Lumiere"
OVERLAY_ARGS=()

VLC_APP=""
if [[ -d /Applications/VLC.app ]]; then
  VLC_APP="/Applications/VLC.app"
elif [[ -d "$HOME/Applications/VLC.app" ]]; then
  VLC_APP="$HOME/Applications/VLC.app"
fi
if [[ -z "$VLC_APP" || ! -f "$VLC_APP/Contents/MacOS/lib/libvlc.dylib" ]]; then
  echo "Нужен установленный VLC.app — Lumiere играет через его libvlc."
  exit 1
fi
VLC_INC="$VLC_APP/Contents/MacOS/include"
VLC_LIB="$VLC_APP/Contents/MacOS/lib"

pkill -x Lumiere 2>/dev/null || true
sleep 0.2

MODULEMAP="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"
BRIDGING="/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap"
if [[ -f "$MODULEMAP" && -f "$BRIDGING" ]]; then
  OVERLAY="$(mktemp)"
  trap 'rm -f "$OVERLAY"' EXIT
  cat > "$OVERLAY" << EOF
{
  "version": 0,
  "roots": [
    {
      "name": "$MODULEMAP",
      "type": "file",
      "external-contents": "$ROOT/Support/empty.modulemap"
    }
  ]
}
EOF
  OVERLAY_ARGS=(-vfsoverlay "$OVERLAY")
fi

# bash 3.2 (системный /bin/bash) с set -u считает пустой массив необъявленным.
swiftc_overlay() {
  if ((${#OVERLAY_ARGS[@]})); then
    swiftc "${OVERLAY_ARGS[@]}" "$@"
  else
    swiftc "$@"
  fi
}

make_icon() {
  local src="$ROOT/icon.png"
  local set="$ROOT/build/AppIcon.iconset"
  local tool="$ROOT/build/mask-icon"
  mkdir -p "$ROOT/Resources" "$ROOT/build"
  if [[ ! -f "$src" ]]; then
    echo "Нет icon.png — иконка не собрана"
    return
  fi
  swiftc_overlay \
    -target "$TARGET" \
    -sdk "$SDK" \
    -framework AppKit \
    -O \
    -o "$tool" \
    "$ROOT/Scripts/mask-icon.swift"
  rm -rf "$set"
  "$tool" "$src" "$set"
  iconutil -c icns "$set" -o "$ROOT/Resources/AppIcon.icns"
  rm -rf "$set"
}

make_icon

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$ROOT/Sources/Lumiere" -name '*.swift' | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "SDK: $SDK"
echo "VLC: $VLC_APP"
echo "Building Lumiere.app…"

swiftc_overlay \
  -target "$TARGET" \
  -sdk "$SDK" \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -I "$ROOT/Support/Clibvlc" \
  -Xcc -I"$VLC_INC" \
  -L "$VLC_LIB" \
  -lvlc \
  -Xlinker -rpath -Xlinker "/Applications/VLC.app/Contents/MacOS/lib" \
  -Xlinker -rpath -Xlinker "$HOME/Applications/VLC.app/Contents/MacOS/lib" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -o "$BIN" \
  "${SOURCES[@]}"

PLIST="$ROOT/Info.plist"
if [[ -n "${LUMIERE_VERSION:-}" ]]; then
  NEXT_VERSION="$LUMIERE_VERSION"
else
  NEXT_VERSION="$(bash "$ROOT/Scripts/next-version.sh")"
fi
if [[ ! "$NEXT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
  echo "Некорректная версия: $NEXT_VERSION"
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_VERSION" "$PLIST"
cp "$PLIST" "$APP/Contents/Info.plist"
echo "Версия $NEXT_VERSION"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/icon.png" "$APP/Contents/Resources/icon.png"

SET_ICON_TOOL="$ROOT/build/set-finder-icon"
swiftc_overlay \
  -target "$TARGET" \
  -sdk "$SDK" \
  -framework AppKit \
  -O \
  -o "$SET_ICON_TOOL" \
  "$ROOT/Scripts/set-finder-icon.swift"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Finder часто не берёт только CFBundleIconFile — кастомная иконка ПОСЛЕ codesign.
"$SET_ICON_TOOL" "$APP" "$ROOT/Resources/AppIcon.icns"

FIX_SRC="$ROOT/Scripts/разрешить-запуск.command"
FIX_DST="$ROOT/build/разрешить-запуск.command"
if [[ -f "$FIX_SRC" ]]; then
  cp "$FIX_SRC" "$FIX_DST"
  chmod +x "$FIX_DST"
fi

if [[ "${LUMIERE_SKIP_INSTALL:-}" == "1" ]]; then
  echo "OK → $APP"
  ls -la "$BIN"
  exit 0
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
/usr/bin/osascript -e "tell application \"Finder\" to update POSIX file \"$APP\"" >/dev/null 2>&1 || true

INSTALLED="/Applications/Lumiere.app"
echo "Копирую в Программы…"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED" >/dev/null 2>&1 || true

echo "OK → $APP"
echo "OK → $INSTALLED"
ls -la "$BIN"

if [[ "${1:-}" == "run" ]]; then
  open -n "$INSTALLED"
fi
