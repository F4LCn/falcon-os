BOOTINFO_MAGIC equ 'FLCN'

BOOTLOADER_BIOS equ 0
BOOTLOADER_UEFI equ 1

MMAP_USED       equ 0
MMAP_FREE       equ 1
MMAP_ACPI       equ 2
MMAP_RECLAIM    equ 3

MAX_BOOTINFO_SZ equ 4096

; bootinfo
virtual at bootinfo
    ; platform independent stuff (64bytes)
    bootinfo.magic              dd 0
    bootinfo.size               dd 0
    bootinfo.bootloader         db 0
    bootinfo.unused0            db 0, 0, 0
    bootinfo.fb_ptr             dq 0
    bootinfo.fb_width           dd 0
    bootinfo.fb_height          dd 0
    bootinfo.fb_scanline        dd 0
    bootinfo.fb_pixelformat     db 0
    bootinfo.unused1            db 31 dup 0

    ; platform dependent stuff (32 bytes)
    bootinfo.acpi_ptr           dq 0
    bootinfo.unused2            db 24 dup 0

    ; memory map
    bootinfo.mmap:
end virtual

; ----------------- GRAPHICS ------------------
VBE_SUPPORTED	equ 1
VBE_COLOR			equ 8
VBE_GRAPHICS		equ 16
VBE_LINEAR_FB		equ 128

VBE_DIRECT_COLOR	equ 6

VBE_MODE_ATTRIB_OFFSET 			equ 0
VBE_MODE_MEMORY_MODEL_OFFSET 	equ 1Bh
VBE_MODE_BPP_OFFSET				equ 19h
VBE_MODE_WIDTH_OFFSET			equ 12h
VBE_MODE_HEIGHT_OFFSET			equ 14h
VBE_MODE_SCANLINE_OFFSET		equ 10h
VBE_MODE_FB_PHYSADDR_OFFSET		equ 28h
VBE_MODE_BLUE_FIELD_SIZE_OFFSET	equ 24h

VBE_FB_ARGB				equ 0
VBE_FB_RGBA				equ 1
VBE_FB_ABGR				equ 2
VBE_FB_BGRA				equ 3
