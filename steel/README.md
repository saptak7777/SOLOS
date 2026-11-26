# S.T.E.E.L. — SOLOS Minimal Host Packagers & Support Modules

Minimal host utilities used to package `BOOTX64.EFI` and `SHARK.BIN` from `.safe` images, plus pure/arena support modules referenced by `sinc_cell/`.

```text
steel/
├── data/
│   └── slice.sinc                # 2-word fat pointer slice helper (sinc_cell)
├── pure/
│   ├── hash.sinc                 # FNV-1a hash helper (sinc_cell)
│   └── sym_table.sinc            # Linear-probing symbol table (sinc_cell)
└── sys/
    ├── arena.sinc                # Zero-fragmentation linear bump allocator
    ├── sys.sinc                  # Minimal host Linux syscall wrappers
    ├── packager_efi.sinc         # .safe -> UEFI PE32+ BOOTX64.EFI emitter
    ├── packager_efi_entry.sinc   # Standalone CLI wrapper -> bin/packager_efi
    ├── packager_kernel.sinc      # .safe -> SHARK.BIN container emitter
    └── packager_kernel_entry.sinc# Standalone CLI wrapper -> bin/packager_kernel
```
