# write an operating system (from scratch)

## constraints
- intel x86_64 arch only
- assume hardware from 2010

## main goals
- 64bit
- smp (symmetric multiprocessing)
- multithreading & preemptive scheduling
- written in c (and a bit of asm)
- (maybe) pci/e device enumeration
- (maybe) pci/e device driver

## tools
- vm: bochs, qemu
- assembler: fasm
- c compiler: clang
- objdump, objcopy, ... or better yet some sort of gnu env (linux, wsl, cygwin)

## documentation
### assembly
- https://www.felixcloutier.com/x86/

### bios
- boot process: http://www.bioscentral.com/misc/biosbasics.htm
- bda: http://www.bioscentral.com/misc/bda.htm
- bios services: http://www.bioscentral.com/misc/biosservices.htm
- bios interrupts details: https://stanislavs.org/helppc/idx_interrupt.html
- bios interrupts details (for newer ints): http://www.delorie.com/djgpp/doc/rbinter/ix/
- memory map: https://wiki.osdev.org/Memory_Map_(x86)
- read from drive: https://en.wikipedia.org/wiki/INT_13H#INT_13h_AH=42h:_Extended_Read_Sectors_From_Drive

### memory:
- addressing: http://www.c-jump.com/CIS77/ASM/Memory/lecture.html
- segmentation: https://en.wikipedia.org/wiki/X86_memory_segmentation

### architecture details:
- i8086 architecture: https://en.wikipedia.org/wiki/Intel_8086#Registers_and_instruction
- x86 architecture: https://en.wikibooks.org/wiki/X86_Assembly/X86_Architecture
- x64 registers: https://upload.wikimedia.org/wikipedia/commons/1/15/Table_of_x86_Registers_svg.svg