use16
real_mode:
    cli
    cld
    xor ax, ax
    mov ss, ax
    mov es, ax
    mov ds, ax
    mov ebx, cs   ; addr = CS << 4 + OFFSET (OFFSET = 0)
    shl ebx, 4    ; ebx = trampoline page addr
    
    mov eax, GDT
    add eax, ebx
    mov dword [GDTR.ptr], eax
    lgdt [cs:GDTR]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    lea eax, [ebx + protected_mode]
    mov word [cs:jumper.offset], ax
    mov word [cs:jumper.segment], 0x18
    mov dword [cs:trampoline_variables.status], 0x01
    jmp far dword [ebx + jumper]

use32
protected_mode:
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    
    mov eax, cr0                            ; disable paging
    and eax, 0x7FFFFFFF
    mov cr0, eax
    mov eax, cr4                            ; enabling fpu/sse
    or eax, 0x620
    mov cr4, eax
    mov eax, dword [ebp + trampoline_variables.page_map]
    mov cr3, eax                            ; set the page map
    mov ecx, 0xC0000080                     ; EFER, enable long mode
    rdmsr
    or eax, 0x101
    wrmsr
    mov eax, cr0                            ; enable paging
    or eax, 0xE000000E
    mov cr0, eax
    lea eax, [ebx + long_mode]
    mov word [cs:jumper.offset], ax
    mov word [cs:jumper.segment], 0x28
    mov dword [cs:trampoline_variables.status], 0x02
    jmp far dword [ebx + jumper]

long_mode:
USE64
    mov rax, trampoline_variables.entrypoint                    ; pop entrypoint from stack
    jmp rax                                 ; handoff exec to kernel
    jmp $                                   ; catch-all in case the kernel returns

align 16
GDTR:
    dw GDT_END - GDT - 1
    .ptr: dd 0xFFFFFFFF

align 16
GDT:
NullEntry:
    dw 0x0      
    dw 0x0      
    db 0x0      
    db 0x0      
    db 0x0      
    db 0x0      
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
LongCode:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x9A
    db 0xAF
    db 0x00
LongData:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92
    db 0xAF
    db 0x00
GDT_END:

jumper:
  .offset:  dw 0
  .segment: dw 0

pad:            db 0x1000 - (trampoline_variables_end - trampoline_variables) - ($ - $$) dup 0

; Trampoline page addr + 4k - sizeof(tampoline_variables struct)
trampoline_variables:
.page_map: dq 0xa0a0a0a0
.entrypoint: dq 0x0b0b0b0b
.status: dw 0
trampoline_variables_end:
