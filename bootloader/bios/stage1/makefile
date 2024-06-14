OUTPUT_DIR = ../../../build

all: bootloader.bin

bootloader.bin:
	fasm bootloader.asm bootloader.bin
	mv bootloader.bin $(OUTPUT_DIR)/bootloader.bin

clean:
	rm -f $(OUTPUT_DIR)/bootloader.bin
