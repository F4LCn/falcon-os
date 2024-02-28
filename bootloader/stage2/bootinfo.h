#ifndef _BOOTINFO_
#define _BOOTINFO_
#include "types.h"

/* bootloader types */
#define BOOTLOADER_BIOS 0
#define BOOTLOADER_UEFI 1

/* framebuffer pixel formats, only 32 bits supported */
#define PIXELFORMAT_ARGB 0
#define PIXELFORMAT_RGBA 1
#define PIXELFORMAT_ABGR 2
#define PIXELFORMAT_BGRA 3

/* memory map types */
#define MMAP_USED 0 /* don't use. Reserved or unknown regions */
#define MMAP_FREE 1 /* usable memory */
// WARN: There's a gap here
// TODO: Fix the gap in asm file too
#define MMAP_ACPI 3        /* acpi memory, volatile and non-volatile as well */
#define MMAP_RECLAIMABLE 4 /* memory mapped IO region */

/* mmap entry, type is stored in least significant byte of ptr
 * but all map entries should be page aligned (1 << 12)
 * so the least significant 12bits are empty anyway
 */
typedef struct {
  u64 ptr;
  u64 size;
} mmap_entry;

typedef struct __attribute((packed)) {
  u8 magic[4];        /* magic bytes are 'FLCN' */
  u32 size;           /* total size of the struct */
  u8 bootloader_type; /* bootloader type (BIOS|UEFI) */
  u8 unused0[3];
  u64 fb_ptr; /* framebuffer pointer and dimensions */
  u32 fb_width;
  u32 fb_height;
  u32 fb_scanline_bytes; /* number of bytes in scanline */
  u8 fb_pixelformat;     /* pixel format */
  u8 unused1[31];
  u64 acpi_ptr;
  u8 unused2[24];
  mmap_entry mmap; /* physical memory map */
} boot_info;

extern boot_info bootinfo;

#endif // !_BOOTINFO_
