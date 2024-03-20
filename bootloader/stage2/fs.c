#include "fs.h"
#include "asm_helper.h"
#include "bit_math.h"
#include "bootinfo.h"
#include "console.h"
#include "gpt.h"
#include "pmm.h"
#include "string.h"

const i8 efi_guid[16] = {0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
                         0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b};

static partition_info boot_partition;
static fat_info fat_fs_info;

partition_info get_boot_partition_from_gpt() {
  gpt_header *gpt =
      (gpt_header *)pm_alloc(sizeof(gpt_header), MMAP_RECLAIMABLE);
  printf("Allocated page at: 0x%X\n", (u64)gpt);
  bios_read_sectors(1, (u32)gpt, 8);
  printf("GPT: Sig=0x%X, PartSt=0x%X, PartCnt=%d\n", *(u64 *)gpt->signature,
         gpt->partition_entries_start, gpt->partition_entries_count);
  u32 partition_entries_start = (u32)gpt->partition_entries_start;
  partition_entry *entry =
      (partition_entry *)((u32)gpt +
                          SECTOR_SIZE * (partition_entries_start - 1));
  for (u32 i = 0; i < gpt->partition_entries_count; ++i) {
    if (entry->type[0] == 0 && entry->start_lba == 0)
      continue;
    if (entry->attr_flags & 2 ||
        __strncmp((const i8 *)entry->type, efi_guid, 16) == 0)
      break;
    entry++;
  }

  if (entry == NULL) {
    printf("Error: could not find a valid boot partition\n");
    while (1)
      ;
  }

  printf("Found EFI partition at LBA 0x%X\n", entry->start_lba);
  partition_info result = {.type = EFI_SYSTEM,
                           .partition_start_lba = entry->start_lba,
                           .partition_end_lba = entry->end_lba};
  return result;
}

inline static u16 get_root_directory_sectors(const bios_param_block *bpb) {
  u16 root_dir_sectors =
      N_UPPER(bpb->root_entry_count * sizeof(dir_entry), bpb->bytes_per_sector);
  return root_dir_sectors;
}

inline static u32 get_fat_size(const bios_param_block *bpb) {
  u32 fat_size;
  if (bpb->table_size_16 != 0) {
    fat_size = bpb->table_size_16;
  } else {
    fat_size = bpb->extended.fat32.table_size_32;
  }
  return fat_size;
}

inline static u32 get_total_sectors(const bios_param_block *bpb) {
  u32 total_sectors;
  if (bpb->total_sectors_16 != 0) {
    total_sectors = bpb->total_sectors_16;
  } else {
    total_sectors = bpb->total_sectors_32;
  }
  return total_sectors;
}

fat_info fat_init(const partition_info *boot_partition) {
  if (boot_partition->type != EFI_SYSTEM) {
    printf("Error: bad partition type\n");
  }

  bios_param_block *bpb =
      (bios_param_block *)pm_alloc(sizeof(bios_param_block), MMAP_RECLAIMABLE);
  bios_read_sectors((u32)boot_partition->partition_start_lba, (u32)bpb, 1);
  printf("BPB: 0x%x (len=%u)\n", (u32)bpb, sizeof(bios_param_block));
  u16 root_dir_sectors = get_root_directory_sectors(bpb);
  u32 fat_sectors_count = get_fat_size(bpb);
  u32 total_sectors = get_total_sectors(bpb);
  u32 data_sectors =
      total_sectors - (bpb->rsrvd_sector_count +
                       fat_sectors_count * bpb->table_count + root_dir_sectors);
  u32 cluster_count = data_sectors / bpb->sectors_per_cluster;

  if (cluster_count < 4085 || cluster_count >= 65525) {
    printf("Error: not a fat16 partition. can't handle it now\n");
    while (1)
      ;
  }

  u32 fat_start_lba =
      (u32)boot_partition->partition_start_lba + bpb->rsrvd_sector_count;
  u16 *fat = (u16 *)pm_alloc(fat_sectors_count * SECTOR_SIZE, MMAP_RECLAIMABLE);
  bios_read_sectors(
      fat_start_lba, (u32)fat,
      (u16)ALIGN_UP(fat_sectors_count, ARCH_PAGE_SIZE / SECTOR_SIZE));
  printf("FAT: 0x%x (len=%u)\n", (u32)fat, fat_sectors_count * SECTOR_SIZE);

  u32 root_dir_start = (u32)boot_partition->partition_start_lba +
                       bpb->rsrvd_sector_count +
                       fat_sectors_count * bpb->table_count;
  dir_entry *root_dir = (dir_entry *)pm_alloc(
      bpb->root_entry_count * sizeof(dir_entry), MMAP_RECLAIMABLE);
  bios_read_sectors(root_dir_start, (u32)root_dir, (u16)root_dir_sectors);
  printf("ROOT_DIR: 0x%x (len=%u)\n", (u32)root_dir,
         bpb->root_entry_count * sizeof(dir_entry));
  fat_info result = {.bpb = bpb, .fat = fat, .root_directory = root_dir};
  return result;
}

void *read_file_from_root(const i8 *filename) {
  u32 filename_len = __strlen(filename);
  if (filename_len > 11) {
    printf("Error: filename too long\n");
    while (1)
      ;
  }
  bool found = FALSE;
  dir_entry *entry = fat_fs_info.root_directory;
  for (; entry->name[0] != 0; entry++) {
    if (entry->attributes & FILE_ATTRIB_VOLUME ||
        entry->attributes & FILE_ATTRIB_DIR ||
        entry->attributes & FILE_ATTRIB_HIDDEN)
      continue;
    if (__strncmp((const i8 *)entry->name, filename, 11) == 0) {
      found = TRUE;
      break;
    }
  }

  if (!found || entry->file_size == 0) {
    return NULL;
  }

  u8 *contents = pm_alloc(entry->file_size, MMAP_RECLAIMABLE);
  u32 index = 0;
  u32 current_cluster = entry->first_cluster;
  u32 data_start_sector =
      (u32)boot_partition.partition_start_lba +
      fat_fs_info.bpb->rsrvd_sector_count +
      get_fat_size(fat_fs_info.bpb) * fat_fs_info.bpb->table_count +
      get_root_directory_sectors(fat_fs_info.bpb);
  do {
    u32 cluster_sector =
        data_start_sector +
        (current_cluster - 2) * fat_fs_info.bpb->sectors_per_cluster;
    bios_read_sectors(cluster_sector, (u32)(contents + index),
                      fat_fs_info.bpb->sectors_per_cluster);
    current_cluster = fat_fs_info.fat[current_cluster];
  } while (current_cluster < 0xFFF8);

  return contents;
}

void fs_init() {
  boot_partition = get_boot_partition_from_gpt();
  fat_fs_info = fat_init(&boot_partition);
}
