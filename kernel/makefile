OUTPUT_DIR = ../build

all: kernel64.elf

kernel64.elf:
	zig build gen-arch -Darch=x86_64 --summary all
	zig build -Darch=x86_64 -Dmax_cpu=8 --release=safe --summary all
	cp zig-out/bin/kernel64.elf $(OUTPUT_DIR)/kernel64.elf

clean:
	rm -f $(OUTPUT_DIR)/kernel64.elf
	rm -rf zig-out
	rm -rf .zig-cache
