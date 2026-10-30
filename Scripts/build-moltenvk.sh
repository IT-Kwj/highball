#!/bin/bash
# Reproducible build of the engine's MoltenVK component: a pinned upstream tag plus Highball's
# patches, x86_64 only (the engine's Wine is x86_64 under Rosetta), packaged as the tarball the
# engine manifest points at. Usage: Scripts/build-moltenvk.sh [tag] [out-dir]
# Set MVK_USE_METAL_PRIVATE_API=1 for a separate private-API archive. For X4:
# MVK_USE_METAL_PRIVATE_API=1 MVK_PATCHES="shadow-import linear-fallback shadow-readback" \
#   Scripts/build-moltenvk.sh v1.4.2
set -euo pipefail
TAG="${1:-v1.4.1}"
OUT="${2:-$(pwd)/build-moltenvk}"
PRIVATE_API="${MVK_USE_METAL_PRIVATE_API:-0}"
case "$PRIVATE_API" in
  0|1) ;;
  *) echo "MVK_USE_METAL_PRIVATE_API must be 0 or 1" >&2; exit 1 ;;
esac
PATCHES="$(cd "$(dirname "$0")/.." && pwd)/spike/patches"
WORK="$(mktemp -d)"
echo "[moltenvk] tag $TAG, work dir $WORK"
git clone -q --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$WORK/src"
cd "$WORK/src"
# Upstream's Makefile passes this setting through GCC_PREPROCESSOR_DEFINITIONS.
# Reject unsupported tags before fetching dependencies or building.
if [ "$PRIVATE_API" = 1 ]; then
  grep -q 'MVK_USE_METAL_PRIVATE_API=1' README.md || {
    echo "$TAG does not document the private-API build setting" >&2; exit 1;
  }
fi
# The patches, by name (spike/patches/moltenvk-<name>.patch), in this order: shadow-import (the Sims,
# 32-bit Vulkan titles) and linear-fallback (Red Dead Redemption 2's linear 3D and mipmapped images). The
# Wine 11 engines ship 1.4.2 with both; the Wine 10 engines ship 1.4.1 with shadow-import only, which
# MVK_PATCHES="shadow-import" builds. The package name lists the patches it carries.
# shadow-readback (2026-10-08, highball#283) goes after shadow-import: it copies what the GPU writes into the
# shadowed memory back to the game's pages when a submission completes, so a 32-bit game's readbacks stop being
# stale; MVK_PATCHES="shadow-import shadow-readback" built moltenvk-1.4.1-shadow-import-1-shadow-readback-1, published
# in the engine-components release and not yet referenced by any engine manifest.
# device-memory-cap (2026-10-27, highball#398) comes next: HB_MVK_DEVICE_MEMORY_PERCENT caps the device-local heap
# and its budget at that share of the Mac's memory, so a game that sizes its streaming from them stops growing
# into swap. Inert unless the variable is set.
# cache-drawid-present and lenient-interfaces (2026-10-29, highball#125) go last, ported from DiAvisoo's
# MoltenVK-Detroit (alexdremov's and squidbus's work in KhronosGroup/MoltenVK#2054) for Detroit: Become Human.
# cache-drawid-present fixes three bugs any game can hit, so it is always on: vkGetPipelineCacheData() wrote
# nothing when the cache size was not known yet, the draw ID of a direct draw was written at the wrong place, and
# a finished present read its swapchain after letting go of the image. lenient-interfaces is inert unless
# HB_MVK_LENIENT_INTERFACES=1: then a vertex attribute the pipeline does not describe gets a placeholder, and a
# color attachment whose float or integer kind differs from the fragment output takes the output's kind. Both
# apply on bare 1.4.2 too. The Wine 11 set, in order: shadow-import linear-fallback shadow-readback
# device-memory-cap cache-drawid-present lenient-interfaces. The .github/workflows/build-moltenvk.yml job runs
# this script with that set.
read -r -a PATCH_NAMES <<< "${MVK_PATCHES:-shadow-import linear-fallback}"
for NAME_ in "${PATCH_NAMES[@]}"; do
  PATCH="$PATCHES/moltenvk-$NAME_.patch"
  echo "[moltenvk] applying $(basename "$PATCH")"
  git apply --check "$PATCH"
  git apply "$PATCH"
done
./fetchDependencies --macos
xcodebuild build -project MoltenVKPackaging.xcodeproj -scheme "MoltenVK Package (macOS only)" \
  -destination "generic/platform=macOS" -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  GCC_PREPROCESSOR_DEFINITIONS="\$(inherited) MVK_USE_METAL_PRIVATE_API=$PRIVATE_API" -quiet
# The dynamic dylib, explicitly: 1.4.2's package also carries static and xcframework copies
# under Package/Release, and `find | head -1` picked one without the patch markers.
DYLIB="Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
test -f "$DYLIB"
# Read the strings once: `strings | grep -q` under pipefail failed when grep stopped reading early
# and strings died of SIGPIPE, which reads as a missing patch (2026-10-07).
MARKS="$(strings -a "$DYLIB")"
for NAME_ in "${PATCH_NAMES[@]}"; do
  grep -q "HIGHBALL $NAME_" <<< "$MARKS" || { echo "patch missing from build: $NAME_"; exit 1; }
done
mkdir -p "$OUT/pkg" && cp "$DYLIB" "$OUT/pkg/libMoltenVK.dylib"
VARIANT=""
if [ "$PRIVATE_API" = 1 ]; then VARIANT="-private-api-1"; fi
NAME="moltenvk-${TAG#v}$(printf -- "-%s-1" "${PATCH_NAMES[@]}")${VARIANT}-x86_64.tar.gz"
tar -czf "$OUT/$NAME" -C "$OUT/pkg" libMoltenVK.dylib
echo "[moltenvk] $OUT/$NAME"
echo "  sha256: $(shasum -a 256 "$OUT/$NAME" | awk '{print $1}')"
echo "  size:   $(stat -f %z "$OUT/$NAME")"
