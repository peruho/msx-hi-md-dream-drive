#!/bin/sh
# fetch-nextor.sh - populate the (gitignored) toolchain/ with the third-party
# pieces the build needs but that we do NOT redistribute:
#
#   toolchain/kernels/Nextor-2.1.4.base.dat   Nextor kernel base file
#   toolchain/mknexrom                         Konamiman's ROM-assembly tool,
#                                              built from source
#
# Both are downloaded from the upstream Nextor repository, pinned to a fixed
# version for reproducibility. See THIRD-PARTY-NOTICES.md.
#
# You still need the Nestor80 assembler (N80) - grab the release for your
# platform from https://github.com/Konamiman/Nestor80/releases and drop the
# binary in toolchain/ (or point N80 at it). Nestor80 has no build step
# here, so it is not fetched automatically.
#
# Usage:  tools/fetch-nextor.sh
set -eu

# --- pinned upstream version -----------------------------------------------
NEXTOR_TAG="v2.1.4"
NEXTOR_KERNEL="Nextor-2.1.4.base.dat"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TC="$ROOT/toolchain"

# --- prerequisites --------------------------------------------------------
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found (install curl)"; exit 2; }
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "ERROR: C compiler '$CC' not found (install clang/gcc or export CC)"; exit 2; }

fetch() {   # fetch <url> <dest>
    echo ">> downloading $(basename "$2")"
    curl -fsSL -o "$2" "$1" || { echo "ERROR: download failed: $1"; exit 1; }
}

mkdir -p "$TC/kernels" "$TC/src"

# --- 1) Nextor kernel base file -------------------------------------------
fetch "https://github.com/Konamiman/Nextor/releases/download/$NEXTOR_TAG/$NEXTOR_KERNEL" \
      "$TC/kernels/$NEXTOR_KERNEL"

# --- 2) mknexrom (build from source) --------------------------------------
fetch "https://raw.githubusercontent.com/Konamiman/Nextor/$NEXTOR_TAG/buildtools/sources/mknexrom.c" \
      "$TC/src/mknexrom.c"
echo ">> building mknexrom"
"$CC" -O2 -o "$TC/mknexrom" "$TC/src/mknexrom.c" || { echo "ERROR: could not build mknexrom"; exit 1; }
chmod +x "$TC/mknexrom"

echo ""
echo "OK. toolchain ready:"
echo "   $TC/kernels/$NEXTOR_KERNEL"
echo "   $TC/mknexrom"
echo ""
echo "Only Nestor80 (N80) is missing from toolchain/ -> then: make own"
