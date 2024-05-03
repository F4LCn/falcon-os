image:
	dd if=/dev/zero of=disk.img bs=1048576 count=10
	printf "g\nn p\n1\n2048\n+8M\nt\n1\nw\n" | fdisk disk.img
	losetup -D
	losetup -o 1048576 -f disk.img
	mkfs.vfat -F 16 -v -n "EFI System" /dev/loop0
	mkdir img
	mount -t vfat,fat=16 /dev/loop0 img
	mkdir -p img/BIOS/BOOT
	mkdir -p img/SYS
	cp stage2.bin img/BIOS/BOOT/STAGE2.BIN
	cp boot.config img/SYS/KERNEL.CON
	cp kernel64.elf img/SYS/KERNEL64.elf
	umount img
	rmdir img
	losetup -D
	./mkboot disk.img bootloader.bin
	mv disk.img ../dist/disk.img

clean:
	rm -f ../dist/disk.img
