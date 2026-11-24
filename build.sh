#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=$ROOT_DIR/scratch
MANIFEST=$ROOT_DIR/stabl/build.staff
STAFF=$ROOT_DIR/bin/staff
PACKAGER_BIN=$ROOT_DIR/bin/packager_bin
PACKAGER_EFI=$ROOT_DIR/bin/packager_efi

mkdir -p "$BUILD_DIR"
"$STAFF" "$MANIFEST" "$BUILD_DIR/stabl.safe"

# 1. Linux userspace test harness payload
"$PACKAGER_BIN" "$BUILD_DIR/stabl.safe" "$BUILD_DIR/stabl.elf"
chmod +x "$BUILD_DIR/stabl.elf"

# 2. Bare-metal UEFI needle BOOTX64.EFI
KERNEL_ARG="${1:-}"
if [[ -n "$KERNEL_ARG" ]]; then
    "$PACKAGER_EFI" "$BUILD_DIR/stabl.safe" "$KERNEL_ARG" "$BUILD_DIR/BOOTX64.EFI"
else
    "$PACKAGER_EFI" "$BUILD_DIR/stabl.safe" "$BUILD_DIR/BOOTX64.EFI"
fi

printf 'Built STABL safe payload: %s\n' "$BUILD_DIR/stabl.safe"
printf 'Built STABL EFI binary:   %s\n' "$BUILD_DIR/BOOTX64.EFI"
