image:
	dd if=/dev/zero of=disk.img bs=1048576 count=10
	printf "g\nn p\n1\n2048\n+8M\nt\n1\nw\n" | fdisk disk.img
	sudo losetup -D
	sudo losetup -o 1048576 -f disk.img
	sudo mkfs.vfat -F 16 -v -n "EFI System" /dev/loop0
	mkdir img
	sudo mount -t vfat,fat=16 /dev/loop0 img
	sudo mkdir -p img/BIOS/BOOT
	sudo mkdir -p img/EFI/BOOT
	sudo mkdir -p img/SYS
	sudo cp stage2.bin img/BIOS/BOOT/STAGE2.BIN
	sudo cp boot.efi img/EFI/BOOT/BOOTx64.EFI
	sudo cp boot.config img/SYS/KERNEL.CON
	sudo cp kernel64.elf img/SYS/KERNEL64.elf
	sudo umount img
	rmdir img
	sudo losetup -D
	./mkboot disk.img bootloader.bin
	mv disk.img ../dist/disk.img

clean:
	rm -f ../dist/disk.img
