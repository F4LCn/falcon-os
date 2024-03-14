use32

format elf

section '.text' executable

public bios_read_sectors

; void bios_read_sectors(u32 start_sector, u32 dst, u32 count)
bios_read_sectors:
    push ebp
    mov ebp, esp
    push edi
    push ecx
    push ebx
    mov eax, dword [ebp + 0x08]
    mov edi, dword [ebp + 0x0c]
    mov ecx, dword [ebp + 0x10]
    mov ebx, 0x9d8
    call ebx
    pop ebx
    pop ecx
    pop edi
    mov esp, ebp
    pop ebp
    ret
