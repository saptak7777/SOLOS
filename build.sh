#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=$ROOT_DIR/scratch
MANIFEST=$ROOT_DIR/stabl/build.staff
KERNEL_MANIFEST=$ROOT_DIR/shark/build.staff
STAFF=$ROOT_DIR/bin/staff
PACKAGER_EFI=$ROOT_DIR/bin/packager_efi
PACKAGER_KERNEL=$ROOT_DIR/bin/packager_kernel

mkdir -p "$BUILD_DIR"
"$STAFF" "$MANIFEST" "$BUILD_DIR/stabl.safe"
"$PACKAGER_EFI" "$BUILD_DIR/stabl.safe" "$BUILD_DIR/BOOTX64.EFI"

"$STAFF" "$KERNEL_MANIFEST" "$BUILD_DIR/shark.safe"
"$PACKAGER_KERNEL" "$BUILD_DIR/shark.safe" "$BUILD_DIR/SHARK.BIN"
cp -f "$ROOT_DIR/shark/data/font_trg_terminus.bin" "$BUILD_DIR/FONT.BIN"

printf 'Built STABL EFI binary:   %s\n' "$BUILD_DIR/BOOTX64.EFI"
printf 'Built SHARK kernel image: %s\n' "$BUILD_DIR/SHARK.BIN"
