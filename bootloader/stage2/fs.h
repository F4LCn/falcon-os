#ifndef __FS__
#define __FS__
#include "types.h"

#define SECTOR_SIZE 512

typedef struct {
  u8 signature[8];
  u32 revision;
  u32 size;
  u32 crc;
  u32 rsrvd;
  u64 current_lba;
  u64 backup_lba;
  u64 first_usable_lba;
  u64 last_usable_lba;
  u8 disk_guid[16];
  u64 partition_entries_start;
  u32 partition_entries_count;
  u32 partition_entry_size;
  u32 partition_entries_crc;
  u8 rsrvd2[420];
} gpt_header;

typedef struct {
  u8 type[16];
  u8 guid[16];
  u64 start_lba;
  u64 end_lba;
  u64 attr_flags;
  u8 name[72];
} partition_entry;

void fs_init();

#endif
