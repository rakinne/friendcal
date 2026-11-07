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

# SHA-256 of every font the app bundles. The Cabinet Grotesk URL is unversioned, so a pinned hash
# is the only thing that stops a changed or tampered file from shipping. Bump a hash only after
# checking the new file on purpose. (A case table, not an associative array: macOS ships bash 3.2.)
expected_sha256() {
  case "$1" in
    CabinetGrotesk-Extrabold.otf) echo 466230933dfcda58406cc3bbdb3e3fbb88c6218821681565cd888efc16b1b389 ;;
    CabinetGrotesk-Bold.otf)      echo f3aa0ce9af505408d9a0420515c6c26dc215130b56acc057d24b3bfc2cda292e ;;
    SourceSans3-Regular.otf)      echo 08df266400933d3178d081a45f94a08814c3e55b4b7dd2e0ff69cb1329f13ab6 ;;
    SourceSans3-Semibold.otf)     echo 36f1cd2c344aa3109e64429bce41a41e4b2b923beb2db19b8dbf9bb56f05a4f9 ;;
    SourceSans3-Bold.otf)         echo 7776ddb9f3eb58683e59f28d558d8896b768c2d0c80799fb3f1c56c54dfd98c9 ;;
    JetBrainsMono-Regular.ttf)    echo a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f ;;
    JetBrainsMono-Medium.ttf)     echo 31c92d01a8a08528b718a43addf0ad3df0af2ca4b7b3290a452f70f358e14d3d ;;
    *) return 1 ;;
  esac
}

# verify <file>: fail unless <file> matches its pinned hash.
verify() {
  local f="$1" want got
  want="$(expected_sha256 "$(basename "$f")")" || { echo "error: no pinned SHA-256 for $(basename "$f")" >&2; exit 1; }
  got="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  if [[ "$got" != "$want" ]]; then
    echo "error: SHA-256 mismatch for $(basename "$f"): got $got, want $want" >&2
    exit 1
  fi
}

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
    verify "$src"
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

# Verify every font the app bundles, by its pinned name (extra files in the folder are not ours to judge).
for f in CabinetGrotesk-Extrabold.otf CabinetGrotesk-Bold.otf SourceSans3-Regular.otf SourceSans3-Semibold.otf \
         SourceSans3-Bold.otf JetBrainsMono-Regular.ttf JetBrainsMono-Medium.ttf; do
  verify "$DEST/$f"
done
echo "done: fonts in ${DEST#$ROOT/} (SHA-256 verified)"
