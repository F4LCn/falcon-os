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