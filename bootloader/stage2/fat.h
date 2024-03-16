#ifndef __FAT__
#define __FAT__
#include "types.h"

#define FILE_ATTRIB_RO 0x01
#define FILE_ATTRIB_HIDDEN 0x02
#define FILE_ATTRIB_SYSTEM 0x04
#define FILE_ATTRIB_VOLUME 0x08
#define FILE_ATTRIB_DIR 0x10
#define FILE_ATTRIB_ARCHIVE 0x20
#define FILE_ATTRIB_DEVICE 0x40
#define FILE_ATTRIB_RESERVED 0x80

typedef struct __attribute((packed)) {
  u32 table_size_32;
  u16 extended_flags;
  u16 fat_version;
  u32 root_cluster;
  u16 fat_info;
  u16 backup_BS_sector;
  u8 reserved_0[12];
  u8 drive_number;
  u8 rsrvd1;
  u8 boot_signature;
  u32 volume_id;
  u8 volume_label[11];
  u8 fat_type_label[8];

} extended_bpb_fat32;

typedef struct __attribute((packed)) {
  u8 bios_drive_num;
  u8 rsrvd1;
  u8 boot_signature;
  u32 volume_id;
  u8 volume_label[11];
  u8 fat_type_label[8];

} extended_bpb_fat16;

typedef struct __attribute((packed)) {
  u8 bootjmp[3];
  u8 oem_name[8];
  u16 bytes_per_sector;
  u8 sectors_per_cluster;
  u16 rsrvd_sector_count;
  u8 table_count;
  u16 root_entry_count;
  u16 total_sectors_16;
  u8 media_type;
  u16 table_size_16;
  u16 sectors_per_track;
  u16 head_side_count;
  u32 hidden_sector_count;
  u32 total_sectors_32;
  union {
    extended_bpb_fat16 fat16;
    extended_bpb_fat32 fat32;
  } extended;
} bios_param_block;

typedef struct __attribute((packed)) {
  u8 name[8];
  u8 ext[3];
  u8 attributes;
  u8 rsrvd;
  u8 create_time_ms;
  u16 create_time;
  u16 create_date;
  u16 access_date;
  u16 extended_attribs_index;
  u16 moditifed_time;
  u16 modified_date;
  u16 first_cluster;
  u32 file_size;
} dir_entry;


#endif
