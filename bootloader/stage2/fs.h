#ifndef __FS__
#define __FS__
#include "fat.h"
#include "types.h"

#define SECTOR_SIZE 512

typedef enum { EFI_SYSTEM, PARTITION_TYPE_COUNT } partition_type;

typedef struct {
  partition_type type;
  u64 partition_start_lba;
  u64 partition_end_lba;
} partition_info;

typedef struct {
  bios_param_block *bpb;
  u16 *fat;
  dir_entry *root_directory;
} fat_info;

void fs_init();
void *read_file_from_root(const i8 *filename);
void *read_file(const i8* path);

#endif
