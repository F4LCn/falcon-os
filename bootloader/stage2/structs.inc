BOOTINFO_MAGIC equ 'FLCN'

BOOTLOADER_BIOS equ 0
BOOTLOADER_UEFI equ 1

MMAP_USED       equ 0
MMAP_FREE       equ 1
MMAP_ACPI       equ 3
MMAP_RECLAIM    equ 4

MAX_BOOTINFO_SZ equ 4096

; bootinfo
virtual at bootinfo
    ; platform independent stuff (64bytes)
    bootinfo.magic              dd 0
    bootinfo.size               dd 0
    bootinfo.bootloader         db 0
    bootinfo.fb_ptr             dq 0
    bootinfo.fb_width           dd 0
    bootinfo.fb_height          dd 0
    bootinfo.fb_scanline        dd 0
    bootinfo.fb_pixelformat     db 0
    bootinfo.unused0            dq 0, 0, 0, 0
    bootinfo.unused1            db 0, 0

    ; platform dependent stuff (32 bytes)
    bootinfo.acpi_ptr           dq 0
    bootinfo.unused2            dq 0, 0, 0

    ; memory map
    bootinfo.mmap:
end virtual