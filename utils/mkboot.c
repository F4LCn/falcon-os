#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>

#define SECTOR_SIZE 512

// mkboot disk.img bootloader.bin
int main(int argc, char **argv) {
    char *disk_filename;
    char *bootloader_filename;
    int disk_fd;
    int bootloader_fd;
    unsigned char data[SECTOR_SIZE];
    int second_stage_sector = -1;
    int sec;
    int read_bytes;

    if (argc < 3) {
        printf("Usage: mkboot disk.img bootloader.bin\n");
        exit(-1);
    }

    disk_filename = argv[1];
    bootloader_filename = argv[2];

    printf("Reading disk image: %s\n", disk_filename);
    disk_fd = open(disk_filename, O_RDONLY);
    if (disk_fd == -1) {
        printf("Couldn't open disk image\n");
        exit(-2);
    }

    if (read(disk_fd, data, SECTOR_SIZE) == -1) {
        close(disk_fd);
        printf("Couldn't read disk image\n");
        exit(-3);
    }

    // 10 * 1024 * 1024 / SECTOR_SIZE = 20480 sectors
    for (sec = 0; sec < 10 * 1024 * 1024; ++sec) {
        read_bytes = read(disk_fd, data, SECTOR_SIZE);
        if (read_bytes == -1) {
            close(disk_fd);
            printf("Couldn't read disk image\n");
            exit(-4);
        }

        if (read_bytes == 0){
            close(disk_fd);
            printf("Couldn't find magic bytes\n");
            exit(-4);
        }

        if (data[0] == 0xF4 && data[1] == 0x1C) {
            printf("Found MAGIC_BYTES @ sector %d\n", sec + 1);
            second_stage_sector = sec + 1;
            break;
        }
    }
    close(disk_fd);

    printf("Reading bootloader: %s\n", bootloader_filename);
    bootloader_fd = open(bootloader_filename, O_RDONLY);
    if (bootloader_fd == -1) {
        printf("Couldn't open bootloader\n");
        exit(-5);
    }
    if (read(bootloader_fd, data, SECTOR_SIZE) == -1) {
        printf("Couldn't read bootloader file\n");
    }
    close(bootloader_fd);

    // FIXME: there's a bug here
    memcpy((void*)&data + 0xd2, (void*)&second_stage_sector, 4);
    // TODO: Figure out the 2nd stage len in sectors

    // need to write 0x1C0 = 448 Bytes to the first sector of our disk
    disk_fd = open(disk_filename, O_WRONLY);
    if (disk_fd == -1) {
        printf("Couldn't open disk image for writing\n");
        exit(-6);
    }

    if (write(disk_fd, data, 0x1BF) <= 0) {
        printf("Couldn't write bootloader\n");
        close(disk_fd);
        exit(-7);
    }
    close(disk_fd);
    printf("Bootloader installed, 2nd stage starts at LBA %d\n", second_stage_sector);
}
