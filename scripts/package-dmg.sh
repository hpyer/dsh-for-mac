#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_VERSION="${DSHFORMAC_VERSION:-0.1.1}"
PACKAGE_ARCH="${DSHFORMAC_ARCH:-universal}"
APP_NAME="DshForMac"
OUTPUT_DIR="$ROOT_DIR/dist"
TRAY_IMAGE="$ROOT_DIR/Sources/DshForMac/Resources/dsh-whale.png"
DOCK_WHALE_IMAGE="$ROOT_DIR/Sources/DshForMac/Resources/dsh-whale-dock.png"
INFO_PLIST="$ROOT_DIR/Packaging/Info.plist"

case "$PACKAGE_ARCH" in
  universal)
    ASSET_SUFFIX=""
    RESOURCE_ARCH="arm64"
    ;;
  x86_64)
    ASSET_SUFFIX="-intel"
    RESOURCE_ARCH="x86_64"
    ;;
  arm64)
    ASSET_SUFFIX="-apple-silicon"
    RESOURCE_ARCH="arm64"
    ;;
  *)
    print -u2 "Unsupported package architecture: $PACKAGE_ARCH"
    exit 1
    ;;
esac

OUTPUT_DMG="$OUTPUT_DIR/${APP_NAME}-${PACKAGE_VERSION}${ASSET_SUFFIX}-unsigned.dmg"

if [[ -e "$OUTPUT_DMG" ]]; then
  print -u2 "Refusing to overwrite existing artifact: $OUTPUT_DMG"
  exit 1
fi

if [[ ! -f "$TRAY_IMAGE" || ! -f "$DOCK_WHALE_IMAGE" || ! -f "$INFO_PLIST" ]]; then
  print -u2 "Required packaging resource is missing."
  exit 1
fi

cd "$ROOT_DIR"
if [[ "${DSHFORMAC_SKIP_BUILD:-0}" != "1" ]]; then
  if [[ "$PACKAGE_ARCH" == "universal" ]]; then
    swift build -c release --arch x86_64
    swift build -c release --arch arm64
  else
    swift build -c release --arch "$PACKAGE_ARCH"
  fi
fi

BINARY_X86_64="${BINARY_X86_64:-$ROOT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME}"
BINARY_ARM64="${BINARY_ARM64:-$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME}"
RESOURCE_BUNDLE="${RESOURCE_BUNDLE:-$ROOT_DIR/.build/${RESOURCE_ARCH}-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle}"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  print -u2 "Release build output is incomplete."
  exit 1
fi

case "$PACKAGE_ARCH" in
  universal)
    if [[ ! -x "$BINARY_X86_64" || ! -x "$BINARY_ARM64" ]]; then
      print -u2 "Release build output is incomplete."
      exit 1
    fi
    ;;
  x86_64)
    if [[ ! -x "$BINARY_X86_64" ]]; then
      print -u2 "Release build output is incomplete."
      exit 1
    fi
    ;;
  arm64)
    if [[ ! -x "$BINARY_ARM64" ]]; then
      print -u2 "Release build output is incomplete."
      exit 1
    fi
    ;;
esac

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dshformac-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

APP_BUNDLE="$STAGING_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_ROOT="$STAGING_DIR/dmg-root"

mkdir -p "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR" "$DMG_ROOT"
case "$PACKAGE_ARCH" in
  universal)
    lipo -create "$BINARY_X86_64" "$BINARY_ARM64" -output "$CONTENTS_DIR/MacOS/$APP_NAME"
    lipo -archs "$CONTENTS_DIR/MacOS/$APP_NAME" | grep -qw x86_64
    lipo -archs "$CONTENTS_DIR/MacOS/$APP_NAME" | grep -qw arm64
    ;;
  x86_64)
    cp "$BINARY_X86_64" "$CONTENTS_DIR/MacOS/$APP_NAME"
    lipo -archs "$CONTENTS_DIR/MacOS/$APP_NAME" | grep -qw x86_64
    ;;
  arm64)
    cp "$BINARY_ARM64" "$CONTENTS_DIR/MacOS/$APP_NAME"
    lipo -archs "$CONTENTS_DIR/MacOS/$APP_NAME" | grep -qw arm64
    ;;
esac
chmod 755 "$CONTENTS_DIR/MacOS/$APP_NAME"
install -m 644 "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
ditto "$RESOURCE_BUNDLE" "$RESOURCES_DIR/${APP_NAME}_${APP_NAME}.bundle"
install -m 644 "$TRAY_IMAGE" "$RESOURCES_DIR/dsh-whale.png"
install -m 644 "$DOCK_WHALE_IMAGE" "$RESOURCES_DIR/dsh-whale-dock.png"
swift "$ROOT_DIR/scripts/render-dock-icon.swift" "$DOCK_WHALE_IMAGE" "$RESOURCES_DIR/${APP_NAME}.icns"

if [[ ! -f "$RESOURCES_DIR/dsh-whale.png" || ! -f "$RESOURCES_DIR/dsh-whale-dock.png" ]]; then
  print -u2 "Application icon image was not packaged."
  exit 1
fi

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
ditto "$APP_BUNDLE" "$DMG_ROOT/${APP_NAME}.app"
ln -s /Applications "$DMG_ROOT/Applications"

mkdir -p "$OUTPUT_DIR"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -format UDZO "$OUTPUT_DMG" >/dev/null
hdiutil verify "$OUTPUT_DMG" >/dev/null

print "Created: $OUTPUT_DMG"
