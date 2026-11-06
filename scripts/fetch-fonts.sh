#!/usr/bin/env bash
# Downloads the 7 app fonts into app/FriendCal/Resources/Fonts.
#
# Cabinet Grotesk (ITF Free Font License 2.0) may be embedded in the app but
# not redistributed through a public repo, so its 2 files are gitignored and
# every fresh clone must run this script. The OFL fonts (Source Sans 3,
# JetBrains Mono) are committed; the script refetches them only if missing.
#
# Usage: scripts/fetch-fonts.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/app/FriendCal/Resources/Fonts"
FORCE="${1:-}"

CABINET_URL="https://api.fontshare.com/v2/fonts/download/cabinet-grotesk"
SOURCE_SANS_URL="https://github.com/adobe-fonts/source-sans/releases/download/3.052R/OTF-source-sans-3.052R.zip"
JETBRAINS_URL="https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip"

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch <name> <url> <file>...: download the zip once, copy each named file
# (matched by basename anywhere in the archive) into $DEST.
fetch() {
  local name="$1" url="$2"; shift 2
  local missing=()
  for f in "$@"; do
    if [[ "$FORCE" == "--force" || ! -f "$DEST/$f" ]]; then missing+=("$f"); fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "ok    $name (already present)"
    return
  fi
  echo "fetch $name"
  local zip="$TMP/$name.zip" dir="$TMP/$name"
  curl -fsSL --retry 2 -o "$zip" "$url"
  mkdir -p "$dir"
  unzip -q -o "$zip" -d "$dir"
  for f in "${missing[@]}"; do
    local src
    src="$(find "$dir" -type f -name "$f" | head -n 1)"
    if [[ -z "$src" ]]; then
      echo "error: $f not found in $url (archive layout changed?)" >&2
      exit 1
    fi
    cp "$src" "$DEST/$f"
    echo "      $f"
  done
}

fetch cabinet-grotesk "$CABINET_URL" \
  CabinetGrotesk-Extrabold.otf CabinetGrotesk-Bold.otf
fetch source-sans-3 "$SOURCE_SANS_URL" \
  SourceSans3-Regular.otf SourceSans3-Semibold.otf SourceSans3-Bold.otf
fetch jetbrains-mono "$JETBRAINS_URL" \
  JetBrainsMono-Regular.ttf JetBrainsMono-Medium.ttf

echo "done: fonts in ${DEST#$ROOT/}"
