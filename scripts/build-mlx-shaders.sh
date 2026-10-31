#!/bin/bash
# Compiles MLX's Metal shaders, which `swift build` can't do, into the file MLX looks
# for next to the executable. Usage: scripts/build-mlx-shaders.sh <output.metallib>
# Needs Xcode's Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$1
SRC=.build/checkouts/mlx-swift/Source/Cmlx/mlx
[[ -d "$SRC/mlx/backend/metal/kernels" ]] || swift package resolve
# Same version pin as the checkout: rebuilt only when mlx-swift or the output changes.
[[ -f "$OUT" && "$OUT" -nt Package.resolved ]] && exit 0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
find "$SRC/mlx/backend/metal/kernels" -name '*.metal' -print0 | xargs -0 -P 8 -I{} sh -c '
    xcrun -sdk macosx metal -x metal -w -fno-fast-math -std=metal4.0 \
        -mmacosx-version-min=26.2 -c "$1" -I"$2" -o "$3/$(basename "$1" .metal).air"' _ {} "$SRC" "$TMP"
mkdir -p "$(dirname "$OUT")"
xcrun -sdk macosx metallib "$TMP"/*.air -o "$OUT"
echo "Built $OUT"
