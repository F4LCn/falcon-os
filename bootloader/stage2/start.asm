org 0x800
use16

; memory map
; 0x0500 - 0x07FF => stage 2 stack
; 0x0800 - 0x9FFF => stage 2 code (loaded by stage 1)
; 0xA000 - 0xAFFF => bootinfo (at max)
; 0xB000 - ?????? => buffers?

include "macros.inc"
include "structs.inc"

bootinfo = 0xA000

magic:          db 0F4h, 01Ch
start:
    xor ax, ax
    mov ds, ax
    mov es, ax

init_bootinfo:
    mov dword eax, BOOTINFO_MAGIC
    mov dword [bootinfo.magic], eax
    mov dword [bootinfo.size], 96
    mov dword [bootinfo.bootloader], BOOTLOADER_BIOS
    xor eax, eax
    mov dword [bootinfo.fb_ptr], eax
    mov dword [bootinfo.fb_ptr + 4], eax
    mov dword [bootinfo.fb_width], eax
    mov dword [bootinfo.fb_height], eax
    mov dword [bootinfo.fb_scanline], eax
    mov byte [bootinfo.fb_pixelformat], 0
    mov dword [bootinfo.acpi_ptr], eax
    mov dword [bootinfo.acpi_ptr + 4], eax

mmap:
    xor ebx, ebx
    mov word di, bootinfo.mmap
.next_map:
    mov ax, 0E820h
    mov dword edx, 0x534D4150
    xor ecx, ecx
    mov byte cl, 20
    int 15h
    jc .no_mmap
    cmp eax, 0x534D4150
    jne .no_mmap
    mov al, [di + 16]
    cmp al, 1
    je .free
    cmp al, 3
    je .reclaimable
    cmp al, 4
    je .acpi
    mov al, MMAP_USED
    jmp @f
.free:
    mov al, MMAP_FREE
    jmp @f
.reclaimable:
    mov al, MMAP_RECLAIM
    jmp @f
.acpi:
    mov al, MMAP_ACPI
@@:
    mov byte [di], al
    add [bootinfo.size], 16
    add di, 16
    cmp di, bootinfo + MAX_BOOTINFO_SZ
    jae @f
    or ebx, ebx
    jnz .next_map
@@:
    cmp [bootinfo.size], 96
    ja .mmap_end
.no_mmap:
    mov si, mmap_error
    jmp panicfunc
.mmap_end:

forever:
    jmp forever

include "helpers.inc"

; variables
panic_prefix:   db "FATAL: ",0
mmap_error:     db "Couldn't map physical memory", 0