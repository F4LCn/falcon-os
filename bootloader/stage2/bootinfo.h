#ifndef _BOOTINFO_
#define _BOOTINFO_
#include "types.h"

typedef struct __attribute((packed)) {
  u8 magic[4];
  u32 size;
  u8 bootloader_type;
  u8 unused0[3];
  u64 fb_ptr;
  u32 fb_width;
  u32 fb_height;
  u32 fb_scanline_bytes;
  u8 fb_pixelformat;
  u8 unused1[31];
  u64 acpi_ptr;
  u8 unused2[24];
  u8 mmap;
} boot_info;

extern boot_info bootinfo;

#endif // !_BOOTINFO_
