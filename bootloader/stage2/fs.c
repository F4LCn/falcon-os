#include "fs.h"
#include "asm_helper.h"
#include "bootinfo.h"
#include "console.h"
#include "pmm.h"
#include "string.h"

const i8 efi_guid[16] = {0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
                         0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b};

void load_gpt() {
  gpt_header *gpt =
      (gpt_header *)pm_alloc(sizeof(gpt_header), MMAP_RECLAIMABLE);
  printf("Allocated page at: 0x%X\n", (u64)gpt);
  bios_read_sectors(1, (u32)gpt, 8);
  printf("GPT: Sig=0x%X, PartSt=0x%X, PartCnt=%d\n", *(u64 *)gpt->signature,
         gpt->partition_entries_start, gpt->partition_entries_count);
  u32 partition_entries_start = (u32)gpt->partition_entries_start;
  partition_entry *entry =
      (partition_entry *)((u32)gpt + SECTOR_SIZE * (partition_entries_start - 1));
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
}

void fs_init() { load_gpt(); }
