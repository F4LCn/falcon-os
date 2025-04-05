OUTPUT_DIR = ../build

all: kernel64.elf

kernel64.elf:
	zig build --release=safe
	cp zig-out/bin/kernel64.elf $(OUTPUT_DIR)/kernel64.elf

clean:
	rm -f $(OUTPUT_DIR)/kernel64.elf
	rm -rf zig-out
	rm -rf .zig-cache
