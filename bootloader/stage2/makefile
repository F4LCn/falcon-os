output_dir = ../../build

all: stage2.bin

stage2.bin:
	fasm start.asm stage2.bin
	mv stage2.bin $(output_dir)/stage2.bin

clean:
	rm -f $(output_dir)/stage2.bin