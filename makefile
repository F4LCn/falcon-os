bootloader:
	make -C bootloader all

kernel:
	make -C kernel all

utils:
	make -C utils utilities

build:
	make -C build image

all: bootloader kernel utils build

clean:
	make -C build clean
	make -C utils clean
	make -C bootloader clean
	make -C kernel clean
