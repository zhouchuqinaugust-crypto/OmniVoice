#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/debug"
APP_NAME="OmniVoice"
APP_IDENTIFIER="com.chuqinzhou.omnivoice"
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CONFIG_DIR="$ROOT_DIR/Config"
STT_BINARY="$ROOT_DIR/vendor/whisper.cpp/build/bin/whisper-cli"
STT_MODEL="$ROOT_DIR/vendor/models/ggml-medium.bin"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT_DIR"

resolve_signing_identity() {
  if [[ -n "${OMNIVOICE_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$OMNIVOICE_CODESIGN_IDENTITY"
    return
  fi

  if [[ -n "${PLAYGROUND_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$PLAYGROUND_CODESIGN_IDENTITY"
    return
  fi

  if command -v security >/dev/null 2>&1; then
    local detected
    detected="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
    if [[ -n "$detected" ]]; then
      printf '%s\n' "$detected"
      return
    fi
  fi

  printf '%s\n' "-"
}

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
  echo "Missing built executable at $BUILD_DIR/$APP_NAME" >&2
  echo "Run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Packaging/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [[ -d "$CONFIG_DIR" ]]; then
  mkdir -p "$RESOURCES_DIR/Config"
  cp "$CONFIG_DIR"/*.json "$RESOURCES_DIR/Config/" 2>/dev/null || true
fi
if [[ -f "$ROOT_DIR/scripts/mlx_transcribe.py" ]]; then
  mkdir -p "$RESOURCES_DIR/scripts"
  cp "$ROOT_DIR/scripts/mlx_transcribe.py" "$RESOURCES_DIR/scripts/mlx_transcribe.py"
fi
if [[ -f "$ROOT_DIR/scripts/mlx_transcribe_file.py" ]]; then
  mkdir -p "$RESOURCES_DIR/scripts"
  cp "$ROOT_DIR/scripts/mlx_transcribe_file.py" "$RESOURCES_DIR/scripts/mlx_transcribe_file.py"
fi
if [[ -x "$STT_BINARY" || -f "$STT_MODEL" ]]; then
  mkdir -p "$RESOURCES_DIR/STT"
  if [[ -x "$STT_BINARY" ]]; then
    cp "$STT_BINARY" "$RESOURCES_DIR/STT/whisper-cli"
  fi
  if [[ -f "$STT_MODEL" ]]; then
    cp "$STT_MODEL" "$RESOURCES_DIR/STT/ggml-medium.bin"
  fi
fi
xattr -rc "$APP_DIR" >/dev/null 2>&1 || true

echo "Built app bundle at: $APP_DIR"
echo "Signing is intentionally deferred to install time because this workspace lives under Documents/File Provider."
