bootloader:
	make -C bootloader all

utils:
	make -C utils utilities

build:
	make -C build image

all: bootloader utils build

clean:
	make -C build clean
	make -C utils clean
	make -C bootloader clean