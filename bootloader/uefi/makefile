OUTPUT_DIR = ../../build

all: boot

boot:
	zig build --release=fast
	cp zig-out/bin/boot.efi $(OUTPUT_DIR)/boot.efi

clean:
	rm -f $(OUTPUT_DIR)/boot.efi
	rm -rf zig-out
	rm -rf .zig-cache
