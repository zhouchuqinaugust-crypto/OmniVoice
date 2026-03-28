#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OmniVoice"
APP_IDENTIFIER="com.chuqinzhou.omnivoice"
SOURCE_APP="$ROOT_DIR/dist/${APP_NAME}.app"
TARGET_APP="/Applications/${APP_NAME}.app"

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

SIGNING_IDENTITY="$(resolve_signing_identity)"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing source app bundle at $SOURCE_APP" >&2
  exit 1
fi

if osascript -e "tell application id \"$APP_IDENTIFIER\" to quit" >/dev/null 2>&1; then
  sleep 0.2
fi

if osascript -e "tell application id \"com.chuqinzhou.playground\" to quit" >/dev/null 2>&1; then
  sleep 0.2
fi

ditto "$SOURCE_APP" "$TARGET_APP"
xattr -rc "$TARGET_APP" >/dev/null 2>&1 || true

if [[ -x "$TARGET_APP/Contents/Resources/STT/whisper-cli" ]]; then
  xattr -rc "$TARGET_APP/Contents/Resources/STT/whisper-cli" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$TARGET_APP/Contents/Resources/STT/whisper-cli"
fi

xattr -rc "$TARGET_APP" >/dev/null 2>&1 || true
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none -i "$APP_IDENTIFIER" "$TARGET_APP"
/usr/bin/codesign -vvv --strict "$TARGET_APP"

open "$TARGET_APP"

echo "Installed app bundle to: $TARGET_APP"
echo "Signing identity: $SIGNING_IDENTITY"
