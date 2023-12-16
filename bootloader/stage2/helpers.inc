;usage
; call set_real_mode
use32
set_real_mode:
    cli
    pop edx
    mov dword [stack_ptr], esp
    jmp 0x8:.real_side
.real_side:
use16
    mov eax, cr0
    and al, 0FEh
    mov cr0, eax
    jmp 0x0:.real_mode_enter
.real_mode_enter:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, word [stack_ptr]
    sti
    jmp dx

;usage
; call set_prot_mode
use16
    cli
    xor edx, edx
    pop dx
    mov dword [stack_ptr], esp
    lgdt [GDTR]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x18:.prot_side
.prot_side:
use32
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, dword [stack_ptr]
    sti
    jmp edx

use16
;usage
; mov si, STR_ADDR
; jmp panicfunc
panicfunc:
    print panic_prefix
    print si
    xor ax, ax
    int 16h
    mov al, 0FEh
    out 64h, al
    jmp far 0FFFFh:0

;usage
; mov si, STR_ADDR
; call printfunc
printfunc:
    lodsb               ; loads [si] into al then (since DF = 0) si++
    or al, al           ; if al == 0
    jz .printfunc_end
    mov ah, byte 0Eh    ; setup the INT10,E interrupt
    mov bx, word 03h
    int 10h             ; call the interrupt
    jmp printfunc
.printfunc_end:
    ret