#!/usr/bin/env bash
# ==============================================================================
# tests/run_gui.sh
# SOLOS Interactive SAGR Niri-Style Desktop Launcher (QEMU + OVMF + USB xHCI Kbd)
# ==============================================================================
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="$ROOT_DIR/scratch"
GUI_ESP="/tmp/solos_gui_esp"
GUI_DISK="/tmp/solos_gui_disk.img"
QEMU="$ROOT_DIR/bin/qemu-system-x86_64"
OVMF="$ROOT_DIR/scratch/OVMF.fd"

"$ROOT_DIR/build.sh"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/selftest/build.staff" "$BUILD_DIR/selftest.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/minit/build.staff" "$BUILD_DIR/minit.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/sagr/build.staff" "$BUILD_DIR/sagr.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/lit_shell/build.staff" "$BUILD_DIR/lit_shell.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/sysmon/build.staff" "$BUILD_DIR/sysmon.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/ls/build.staff" "$BUILD_DIR/ls.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/cat/build.staff" "$BUILD_DIR/cat.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/rm/build.staff" "$BUILD_DIR/rm.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/build/build.staff" "$BUILD_DIR/build.safe"
"$ROOT_DIR/bin/staff" "$ROOT_DIR/coreutils/pkg/build.staff" "$BUILD_DIR/pkg.safe"

printf 'fn main() [\n    ret 100;\n]\n' > "$BUILD_DIR/v1.sinc"
"$ROOT_DIR/bin/sinc" "$BUILD_DIR/v1.sinc" "$BUILD_DIR/v1.safe"
printf 'fn main() [\n    ret 200;\n]\n' > "$BUILD_DIR/v2.sinc"
"$ROOT_DIR/bin/sinc" "$BUILD_DIR/v2.sinc" "$BUILD_DIR/v2.safe"
printf 'fn main() [\n    ret 77;\n]\n' > "$BUILD_DIR/app.sinc"
"$ROOT_DIR/bin/trg_encode" "$BUILD_DIR/app.sinc" "$BUILD_DIR/app.trg"
python3 -c "open('$BUILD_DIR/bad1.trg', 'wb').write(b'BAD1' * 20)"
printf 'fn main() [\n    ret nope;\n]\n' > "$BUILD_DIR/bad2.sinc"
"$ROOT_DIR/bin/trg_encode" "$BUILD_DIR/bad2.sinc" "$BUILD_DIR/bad2.trg"

if [[ ! -f "$BUILD_DIR/sinc.safe" ]]; then
    SINC_WS="$BUILD_DIR/sinc_cell_ws"
    rm -rf "$SINC_WS" && mkdir -p "$SINC_WS"
    cp -r "$ROOT_DIR/../SINC/sinc" "$SINC_WS/sinc"
    cp -r "$ROOT_DIR/../SINC/steel" "$SINC_WS/steel"
    cp -r "$ROOT_DIR/sinc_cell" "$SINC_WS/sinc_cell"
    python3 -c "
p = '$SINC_WS/sinc/sys/entry.sinc'
s = open(p, 'r').read()
for old, new in [
    ('global_scratch_tape = arena_alloc_words!(arena, 1048576);', 'global_scratch_tape = arena_alloc_words!(arena, 131072);'),
    ('ctx@[14] = arena_init!(arena_alloc_words!(arena, 131072), 1048576);', 'ctx@[14] = arena_init!(arena_alloc_words!(arena, 65536), 524288);'),
    ('code_buffer = arena_alloc_words!(arena, 5000000);', 'code_buffer = arena_alloc_words!(arena, 262144);'),
    ('40000000', '2097152'),
]:
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
"
    (cd "$SINC_WS" && "$ROOT_DIR/bin/staff" "sinc_cell/build.staff" "$BUILD_DIR/sinc.safe")
fi

rm -rf "$GUI_ESP"
mkdir -p "$GUI_ESP/EFI/BOOT" "$GUI_ESP/EFI/SOLOS"
cp "$BUILD_DIR/BOOTX64.EFI" "$GUI_ESP/EFI/BOOT/BOOTX64.EFI"
cp "$BUILD_DIR/SHARK.BIN" "$GUI_ESP/EFI/SOLOS/SHARK.BIN"
cp "$ROOT_DIR/shark/data/font_trg_terminus.bin" "$GUI_ESP/EFI/SOLOS/FONT.BIN"

dd if=/dev/zero of="$GUI_DISK" bs=1M count=4 status=none
python3 -c "
def fnv1a_64(data):
    h = 14695981039346656037
    for b in data:
        h = ((h ^ b) * 1099511628211) & 0xffffffffffffffff
    return h

def make_entry(ty, pages, start_pg, size, h, q0, q1):
    e = bytearray(64)
    meta = (ty & 255) | (1 << 16) | (pages << 32)
    e[0:8]   = int(meta).to_bytes(8, 'little')
    e[8:16]  = int(start_pg).to_bytes(8, 'little')
    e[16:24] = int(size).to_bytes(8, 'little')
    e[24:32] = int(h).to_bytes(8, 'little')
    e[40:48] = int(q0).to_bytes(8, 'little', signed=True)
    e[48:56] = int(q1).to_bytes(8, 'little', signed=True)
    return bytes(e)

with open('$GUI_DISK', 'r+b') as f:
    total_pages = 1024
    sb = bytearray(4096)
    sb[0:8]   = int(1163084099).to_bytes(8, 'little')
    sb[8:16]  = int(1).to_bytes(8, 'little')
    sb[16:24] = int(1).to_bytes(8, 'little')
    sb[24:32] = int(total_pages).to_bytes(8, 'little')

    bitmap = bytearray(4096)
    def mark_used(s, n):
        for p in range(s, s + n):
            bitmap[p >> 3] |= (1 << (p & 7))
    mark_used(0, 25)

    specs = [
        (1, 3255009809826913836, 129370828029, open('$BUILD_DIR/selftest.safe', 'rb').read()),
        (1, 8478446585722159, 0, open('$BUILD_DIR/v1.safe', 'rb').read()),
        (1, 8478446585722415, 0, open('$BUILD_DIR/v2.safe', 'rb').read()),
        (1, 1886160714249740838, 7711, open('$BUILD_DIR/minit.safe', 'rb').read()),
        (1, 2241153230432115244, 30, open('$BUILD_DIR/sagr.safe', 'rb').read()),
        (1, 2674611705646752293, 33118931975461, open('$BUILD_DIR/lit_shell.safe', 'rb').read()),
        (1, 3241790360169230892, 1974042, open('$BUILD_DIR/sysmon.safe', 'rb').read()),
        (1, 2241153230180917804, 30, open('$BUILD_DIR/sinc.safe', 'rb').read()),
        (1, 8478446585719845, 0, open('$BUILD_DIR/ls.safe', 'rb').read()),
        (1, 2170482325944343068, 0, open('$BUILD_DIR/cat.safe', 'rb').read()),
        (1, 8478446585718315, 0, open('$BUILD_DIR/rm.safe', 'rb').read()),
        (1, 1886160645580271131, 7711, open('$BUILD_DIR/build.safe', 'rb').read()),
        (1, 2170482325943493673, 0, open('$BUILD_DIR/pkg.safe', 'rb').read()),
        (2, 9054675775596826, 0, open('$BUILD_DIR/app.trg', 'rb').read()),
        (2, 2317996998753327643, 0, open('$BUILD_DIR/bad1.trg', 'rb').read()),
        (2, 2317996998770104859, 0, open('$BUILD_DIR/bad2.trg', 'rb').read()),
        (3, 2174994691599248928, 0, b'LIVE'),
    ]

    table = bytearray(8192)
    next_pg = 25
    for i, (ty, q0, q1, data) in enumerate(specs):
        pages = max(1, (len(data) + 4095) // 4096)
        assert next_pg + pages <= total_pages
        f.seek(next_pg * 4096)
        f.write(data)
        table[i*64 : (i+1)*64] = make_entry(ty, pages, next_pg, len(data), fnv1a_64(data), q0, q1)
        mark_used(next_pg, pages)
        next_pg += pages

    hi_data = bytes([0xAA, 0x55]) * 32
    f.seek(next_pg * 4096)
    f.write(hi_data)
    table[70*64 : 71*64] = make_entry(3, 1, next_pg, len(hi_data), fnv1a_64(hi_data), 3249943054441456161, 0)
    mark_used(next_pg, 1)

    f.seek(16 * 4096); f.write(sb)
    f.seek(17 * 4096); f.write(bitmap)
    f.seek(18 * 4096); f.write(table)
"

if [[ "${1:-}" == "--prep-only" ]]; then
    exit 0
fi

QEMU_ARGS=(
  "$QEMU"
  -enable-kvm -cpu host -m 512M
  -bios "$OVMF" -net none
  -drive "format=raw,file=fat:rw:$GUI_ESP"
  -drive "file=$GUI_DISK,if=none,id=drv0,format=raw"
  -device nvme,serial=solos001,drive=drv0
  -device qemu-xhci -device usb-kbd
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
  -no-reboot
)

echo "Launching SOLOS SAGR Desktop..."
echo "  Keys: Alt+Enter (Terminal)  Alt+S (Sysmon)  Alt+H/J/K/L (Focus)  Alt+R (Width)"
echo "        Alt+T (Stack/Tab)     Alt+I/O (Consume/Expel)  Alt+1..4 (WS)  Alt+Shift+Q (Quit)"

DISP_MODE="${SAGR_DISPLAY:-auto}"
if [[ "${1:-}" == "--vnc" ]]; then
    DISP_MODE="vnc"
fi

if [[ "$DISP_MODE" == "auto" ]]; then
    HELP_DISP="$("$QEMU" -display help 2>/dev/null || true)"
    if grep -qx "gtk" <<< "$HELP_DISP"; then
        DISP_MODE="gtk"
    elif grep -qx "sdl" <<< "$HELP_DISP"; then
        DISP_MODE="sdl"
    elif [[ -n "${DISPLAY:-}" ]] && python3 -c "import PyQt6" 2>/dev/null; then
        DISP_MODE="qt"
    else
        DISP_MODE="vnc"
    fi
fi

rc=0
case "$DISP_MODE" in
    gtk|sdl)
        "${QEMU_ARGS[@]}" -display "$DISP_MODE" || rc=$?
        ;;
    qt)
        python3 "$ROOT_DIR/tests/sagr_viewer.py" "${QEMU_ARGS[@]}" || rc=$?
        ;;
    vnc)
        echo "Starting headless VNC on 127.0.0.1:5900 (-vnc 127.0.0.1:0)..."
        "${QEMU_ARGS[@]}" -vnc 127.0.0.1:0 -display none || rc=$?
        ;;
    *)
        echo "Unknown SAGR_DISPLAY mode '$DISP_MODE' (use auto, qt, gtk, sdl, vnc)" >&2
        exit 2
        ;;
esac
if [[ $rc -ne 0 && $rc -ne 85 ]]; then
    exit $rc
fi
