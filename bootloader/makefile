output_dir = ../build

all: bootloader.bin

bootloader.bin:
	fasm bootloader.asm bootloader.bin
	mv bootloader.bin $(output_dir)/bootloader.bin

clean:
	rm -f $(output_dir)/bootloader.bin