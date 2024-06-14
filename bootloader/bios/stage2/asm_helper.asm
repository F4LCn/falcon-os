use32

format elf

section '.text' executable

public bios_read_sectors
public switch_long_mode

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

; void switch_long_mode(u32 page_map_addr, u64 kernel_entrypoint)
switch_long_mode:
    push ebp
    mov ebp, esp
    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax
    mov eax, cr4
    or eax, 0x620
    mov cr4, eax
    mov eax, dword [ebp+0x8]
    mov cr3, eax
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x101
    wrmsr
    mov eax, cr0
    or eax, 0xE000000E
    mov cr0, eax
    mov ebx, dword [ebp + 0xc]
    mov edx, dword [ebp + 0x10]
    push edx
    push ebx
    jmp 0x28:.long_mode
.long_mode:
USE64
    pop rax
    jmp rax
    jmp $
