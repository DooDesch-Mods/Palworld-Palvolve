#!/usr/bin/env bash
# Repacks the GitHub release zip into a Thunderstore (unreal-shimloader) package
# and generates the thunderstore.toml that tcli publish needs.
#
# Usage: bash publishing/build-thunderstore.sh <version>
# Expects dist/Palvolve-v<version>.zip to exist (the GitHub release asset).
set -euo pipefail

VERSION="${1:?usage: build-thunderstore.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/publishing/publish-config.json"
DIST="$ROOT/dist"
SRC_ZIP="$DIST/Palvolve-v$VERSION.zip"
OUT="$DIST/thunderstore"
STAGE="$OUT/stage"

TEAM=$(jq -r '.thunderstore.team' "$CFG")
PKG=$(jq -r '.thunderstore.package' "$CFG")
COMMUNITY=$(jq -r '.thunderstore.community' "$CFG")
SHIMLOADER=$(jq -r '.thunderstore.shimloaderDependency' "$CFG")
DESC=$(tr -d '\r\n' < "$ROOT/publishing/thunderstore/manifest-description.txt")

[ -f "$SRC_ZIP" ] || { echo "missing $SRC_ZIP (download the release asset first)" >&2; exit 1; }
[ "${#DESC}" -le 250 ] || { echo "manifest description exceeds 250 chars (${#DESC})" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$STAGE/mod"
unzip -q "$SRC_ZIP" -d "$STAGE/src"

# shimloader layout: the zip's mod/ folder is the UE4SS lua mod itself;
# enabled.txt is required by shimloader or the mod will not load
cp -r "$STAGE/src/Mods/Palvolve/scripts" "$STAGE/mod/scripts"
touch "$STAGE/mod/enabled.txt"
cp "$STAGE/src/CHANGELOG.md" "$STAGE/CHANGELOG.md"
cp "$ROOT/publishing/thunderstore/README.md" "$STAGE/README.md"
cp "$ROOT/publishing/thunderstore/icon.png" "$STAGE/icon.png"

# shimloader dependency string is "<Team>-<Package>-<Version>"
DEP_KEY="${SHIMLOADER%-*}"
DEP_VER="${SHIMLOADER##*-}"

jq -n \
  --arg name "$PKG" \
  --arg ver "$VERSION" \
  --arg desc "$DESC" \
  --arg url "https://github.com/DooDesch-Mods/Palworld-Palvolve" \
  --arg dep "$SHIMLOADER" \
  '{name: $name, version_number: $ver, website_url: $url, description: $desc, dependencies: [$dep]}' \
  > "$STAGE/manifest.json"

cat > "$OUT/thunderstore.toml" <<EOF
[config]
schemaVersion = "0.0.1"

[package]
namespace = "$TEAM"
name = "$PKG"
versionNumber = "$VERSION"
description = "$DESC"
websiteUrl = "https://github.com/DooDesch-Mods/Palworld-Palvolve"
containsNsfwContent = false

[package.dependencies]
$DEP_KEY = "$DEP_VER"

[build]
icon = "./stage/icon.png"
readme = "./stage/README.md"
outdir = "./build"

[publish]
repository = "https://thunderstore.io"
communities = ["$COMMUNITY"]

[publish.categories]
$COMMUNITY = []
EOF

ZIP_NAME="$TEAM-$PKG-$VERSION.zip"
rm -rf "$STAGE/src"
(cd "$STAGE" && zip -q -r "../$ZIP_NAME" manifest.json README.md CHANGELOG.md icon.png mod)

echo "built $OUT/$ZIP_NAME"
unzip -l "$OUT/$ZIP_NAME"
