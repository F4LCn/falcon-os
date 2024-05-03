OUTPUT_DIR = ../build
ENTRYPOINT_OBJ = main.o
C_SRC_FILES = $(wildcard *.c)
ASM_SRC_FILES = $(wildcard *.asm)
C_OBJ_FILES = $(subst main.o, , $(notdir $(patsubst %.c,%.o,$(C_SRC_FILES))))
ASM_OBJ_FILES = $(filter-out start.o, $(notdir $(patsubst %.asm, %.o,$(ASM_SRC_FILES))))

all: kernel64.elf

kernel64.o:
	@clang -O3 -ggdb -m64 -march=x86-64 --target=x86_64-pc-none-elf -ffreestanding -masm=intel -mno-sse -Wall -Wextra -o kernel64.o -c kernel_stub.c
	
kernel64.elf: kernel64.o
	@ld -melf_x86_64 -T linker.ld -nostdlib -o kernel64.elf kernel64.o
	mv kernel64.elf $(OUTPUT_DIR)/kernel64.elf

clean:
	rm -f $(OUTPUT_DIR)/kernel64.elf
