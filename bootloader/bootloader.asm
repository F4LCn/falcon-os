org 0x7C00
use16

; LBA Packet struct
;Offset	Size	Description
; 0	    1	    size of packet (16 bytes)
; 1	    1	    always 0
; 2	    2	    number of sectors to transfer (max 127 on some BIOSes)
; 4	    4	    transfer buffer (16 bit segment:16 bit offset) (see note #1)
; 8	    4	    lower 32-bits of 48-bit starting LBA
;12	    4	    upper 16-bits of 48-bit starting LBA
lba_packet equ 07E00h
virtual at lba_packet
lba_packet.size        : dw         ?
lba_packet.count       : dw         ?
lba_packet.offset      : dw         ?
lba_packet.segment     : dw         ?
lba_packet.sector0     : dw         ?
lba_packet.sector1     : dw         ?
lba_packet.sector2     : dw         ?
lba_packet.sector3     : dw         ?
end virtual


macro print msg {
if ~ msg eq si
    push si
    mov si, msg
end if
    call printfunc
if ~ msg eq si
    pop si
end if
}

; stack end: 0x500
; sp, bp: 0x600

.start:
    cli
    cld
    xor ax, ax
    mov ss, ax
    mov es, ax
    mov sp, 600h
    mov bp, 600h
    push cs
    pop ds

.check_disk:
    mov byte [boot_drive], dl
    cmp dl, byte 080h
    jl .not_hdd
.is_hdd:
    mov ah, byte 41h
    mov bx, word 55AAh
    int 13h
    jc .not_lba
    cmp bx, 0AA55h
    jne .not_lba
    test cl, byte 1
    jnz .lba_ok

.not_lba:
    mov si, lba_not_found
    jmp panicfunc
.not_hdd:
    mov si, not_hdd
    jmp panicfunc

.lba_ok:
    mov word [lba_packet.size], 16
    mov word [lba_packet.count], 60      ; read 1 sector for now, needs to change when we have a 2nd stage
    mov word [lba_packet.segment], 0h
    mov word [lba_packet.offset], 0800h

    mov word [lba_packet.sector0], 89    ; dword (lower 32-bits of the sector num) [sector0][sector1]
    mov word [lba_packet.sector1], 0
    mov word [lba_packet.sector2], 0
    mov word [lba_packet.sector3], 0

;results
;CF 	Set On Error, Clear If No Error
;AH 	Return Code
    mov ah, 42h
    mov si, lba_packet
    int 13h
    jnc .read_success
    mov si, sector_read_error
    jmp panicfunc

.read_success:
    mov bx, [magic_bytes]
    mov cx, word [800h]
    cmp cx, bx
    jne .bad_magic
    mov ax, 802h
    jmp ax

.bad_magic:
    mov si, invalid_magic
    jmp panicfunc

forever:
    jmp forever

;usage
; mov si, STR_ADDR
; jmp panicfunc
panicfunc:
    print panic_prefix
    print si
    xor ax, ax
    int 16h
    ; the first instr 0xFFFF00
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

; variables
boot_drive:      db 0
magic_bytes:     db 0F4h, 1Ch          ; 0xF41C
stage_2_start:   dd 0xFFFFFFFF

; error messages
panic_prefix:   db "B00T PANIC: ",0
lba_not_found:  db "Hard drive doesnt support LBA packet struct",0
not_hdd:  db "Not a valid harddrive",0
sector_read_error:  db "Couldn't read sector from drive",0
invalid_magic:  db "Sector doesnt start with the expected magic bytes",0

; padding and boot signature
pad:            db 510 - ($ - $$) dup 0
boot_sig:       db 55h, 0AAh