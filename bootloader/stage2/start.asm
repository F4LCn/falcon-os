org 0x800
use16

; memory map
; 0x0500 - 0x07FF => stage 2 stack
; 0x0800 - 0x9FFF => stage 2 code (loaded by stage 1)
; 0xA000 - 0xAFFF => bootinfo (at max)
; 0xB000 - 0xBFFF => tmp_buffer for VBE info
; 0xC000 - ?????? => buffers?

include "macros.inc"
include "structs.inc"

bootinfo = 0xA000
tmp_buffer = 0xB000

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

.find_video_mode:
    xor eax, eax
    mov ax, 04F00h
    mov di, tmp_buffer
    mov dword [di], 'VBE2'
    int 10h
    cmp ax, 004Fh
    je .load_mode_ptrs
.vbe_error:
    mov si, no_vbe_info
    jmp panicfunc

.load_mode_ptrs:
    xor esi, esi
    xor edi, edi
    mov si, word [tmp_buffer + 0Eh]
    mov ax, word [tmp_buffer + 10h]
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov di, tmp_buffer + 200h
    xor bx, bx
.read_next_ptr:
    lodsw
    cmp ax, 0FFFFh
    je @f
    or ax, ax
    jz @f
    stosw
    inc bx
    jmp .read_next_ptr
 @@:
    xor ax, ax
    stosw

.loop_modes:
    mov si, tmp_buffer + 200h
.next_mode:
    mov di, tmp_buffer + 400h
    xor eax, eax
    lodsw
    or ax, ax
    jnz @f
.mode_error:
    mov si, mode_not_found
    jmp panicfunc
@@:
    mov cx, ax
    mov ax, 04F01h
    int 10h
    cmp ax, 004Fh
    jne .mode_error

    mov ax, word [tmp_buffer + 400h + VBE_MODE_ATTRIB_OFFSET]
VBE_MODEFLAGS = VBE_SUPPORTED + VBE_COLOR + VBE_GRAPHICS + VBE_LINEAR_FB
    and ax, VBE_MODEFLAGS
    cmp ax, VBE_MODEFLAGS
    jne .next_mode
    cmp byte [tmp_buffer + 400h + VBE_MODE_MEMORY_MODEL_OFFSET], VBE_DIRECT_COLOR
    jne .next_mode
    cmp byte [tmp_buffer + 400h + VBE_MODE_BPP_OFFSET], 32
    jne .next_mode
    cmp word [tmp_buffer + 400h + VBE_MODE_WIDTH_OFFSET], required_width
    jb .next_mode
    cmp word [tmp_buffer + 400h + VBE_MODE_HEIGHT_OFFSET], required_height
    jb .next_mode
.found_match:
    xor edx, edx
    xor ebx, ebx
    xor eax, eax
    mov bx, word [tmp_buffer + 400h + VBE_MODE_SCANLINE_OFFSET]
    mov word [bootinfo.fb_scanline], bx
    mov ax, word [tmp_buffer + 400h + VBE_MODE_WIDTH_OFFSET]
    mov word [bootinfo.fb_width], ax
    mov ax, word [tmp_buffer + 400h + VBE_MODE_HEIGHT_OFFSET]
    mov word [bootinfo.fb_height], ax
    mov eax, dword [tmp_buffer + 400h + VBE_MODE_FB_PHYSADDR_OFFSET]
    mov dword [bootinfo.fb_ptr], eax
    mov byte [bootinfo.fb_pixelformat], VBE_FB_ARGB
    cmp dword [tmp_buffer + 400h + VBE_MODE_BLUE_FIELD_SIZE_OFFSET], 0
    je .video_mode_selected
    mov byte [bootinfo.fb_pixelformat], VBE_FB_RGBA
    cmp dword [tmp_buffer + 400h + VBE_MODE_BLUE_FIELD_SIZE_OFFSET], 8
    je .video_mode_selected
    mov byte [bootinfo.fb_pixelformat], VBE_FB_ABGR
    cmp dword [tmp_buffer + 400h + VBE_MODE_BLUE_FIELD_SIZE_OFFSET], 16
    je .video_mode_selected
    mov byte [bootinfo.fb_pixelformat], VBE_FB_BGRA
.video_mode_selected:

.set_video_mode:
    mov bx, cx
    bts bx, 14
    mov ax, 04F02h
    int 10h
    cmp ax, 004Fh
    je @f
.set_mode_error:
    mov si, set_mode_error
    jmp panicfunc

@@:
    cli
    lgdt [GDTR]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x18:(.protected_start - $$ + 0x800)

use32
.protected_start:
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x800
    mov ebp, 0x800
    jmp 0x18:cmain

include "helpers.inc"

; variables
panic_prefix:   db "FATAL: ",0
mmap_error:     db "Couldn't map physical memory", 0
no_vbe_info:    db "Couldn't find vbe info", 0
mode_not_found:    db "Couldn't find vbe modes", 0
set_mode_error:    db "Couldn't set vbe mode", 0
found_mode:    db "FOUND MODE", 0

required_width = 800
required_height = 600

use32
align 8
stack_ptr:  dd  0

align 16
GDTR:
    dw GDT_END - GDT - 1
    dd GDT

align 16
GDT:
NullEntry:
    dw 0x0      ; Limit [0..15]
    dw 0x0      ; Base [0..15]
    db 0x0      ; Base [16..23]
    db 0x0      ; Access (access bits)
    db 0x0      ; Flags << 4 | Limit [16..19]
    db 0x0      ; Base [24..31]
RealCode:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0x00
    db 0x00
RealData:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0x00
    db 0x00
ProtCode:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xCF
    db 0x00
ProtData:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xCF
    db 0x00
GDT_END:

align 32
padding:
            dq 16 dup 0
cmain: