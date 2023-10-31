image:
	dd if=/dev/zero of=disk.img bs=1048576 count=10
	printf "g\nn p\n1\n2048\n+8M\nt\n1\nw\n" | fdisk disk.img
	losetup -D
	losetup -o 512 -f disk.img
	mkfs.vfat -F 16 -v -n "EFI System" /dev/loop0
	mkdir img
	mount -t vfat,fat=16 /dev/loop0 img
	mkdir -p img/BIOS/BOOT
	cp second.bin img/BIOS/BOOT/STAGE2.BIN
	umount img
	rmdir img
	losetup -D
	./mkboot disk.img bootloader.bin
	mv disk.img ../dist/disk.img

clean:
	rm -f ../dist/disk.img