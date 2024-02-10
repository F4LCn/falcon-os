OUTPUT_DIR = ../../build
ENTRYPOINT_OBJ = main.o
C_SRC_FILES = $(wildcard *.c)
ASM_SRC_FILES = $(wildcard *.asm)
C_OBJ_FILES = $(subst main.o, , $(notdir $(patsubst %.c,%.o,$(C_SRC_FILES))))
ASM_OBJ_FILES = $(filter-out start.o, $(notdir $(patsubst %.asm, %.o,$(ASM_SRC_FILES))))

all: stage2.bin

stage2.bin: start.bin main.elf
	@objcopy -j .text -j .data -j .rodata -j .bss -O binary $(OUTPUT_DIR)/main.elf $(OUTPUT_DIR)/main.bin
	@cat $(OUTPUT_DIR)/start.bin $(OUTPUT_DIR)/main.bin > $(OUTPUT_DIR)/stage2.bin

start.bin:
	fasm start.asm start.bin
	mv start.bin $(OUTPUT_DIR)/start.bin

main.elf: $(ENTRYPOINT_OBJ) $(ASM_OBJ_FILES) $(C_OBJ_FILES)
	@ld -melf_i386 -T linker.ld -nostdlib -o $@ $^
	mv main.elf $(OUTPUT_DIR)/main.elf

%.o: %.c
	@clang -O3 -ggdb -m32 -march=i386 --target=i686-pc-none-elf -ffreestanding -masm=intel -mno-sse -Wall -Wextra -c $<

%.o: %.asm
	@fasm $< $@

clean:
	rm -f $(OUTPUT_DIR)/start.bin