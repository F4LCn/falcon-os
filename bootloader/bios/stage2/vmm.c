#include "vmm.h"
#include "bit_math.h"
#include "bootinfo.h"
#include "console.h"
#include "pmm.h"
#include "string.h"

static inline void write_mapping_entry(volatile page_mapping_entry *entry,
                                       paddr paddr, u32 flags,
                                       bool disable_execution) {
  u32 upper_flags = disable_execution ? (u32)VM_FLAGS_XD : 0;
  u32 lower_flags = flags;

  u32 upper_addr = (paddr.value >> 32);
  u32 lower_addr = paddr.value & 0xffffffff;

  entry->upper = upper_addr | upper_flags;
  entry->lower = lower_addr | lower_flags;
}

static inline page_mapping_entry *
get_or_create_level(volatile page_mapping_entry *mapping, u32 idx) {
  page_mapping_entry *ret;
  volatile page_mapping_entry *next_level = &mapping[idx];
  if ((next_level->lower & VM_FLAGS_P) == 0) {
    ret = (page_mapping_entry *)pm_alloc(ARCH_PAGE_SIZE, MMAP_PAGING);
    __memset(ret, 0, ARCH_PAGE_SIZE);
    write_mapping_entry(next_level, (paddr){.value = (u64)ret},
                        VM_DEFAULT_FLAGS, FALSE);
  } else {
    u64 upper_addr = (u64)(next_level->upper & (u32)~VM_FLAGS_XD);
    u64 lower_addr = (u64)(next_level->lower & (u32)~0xfff);
    u64 addr = (upper_addr << 32) | lower_addr;
    ret = (page_mapping_entry *)addr;
  }
  return ret;
}

void mmap_to_addr(const page_map *page_map, vaddr vaddr, paddr paddr, u32 flags,
                  bool disable_execution) {
  paddr.value = ALIGN_DOWN(paddr.value, ARCH_PAGE_SIZE);
  volatile page_mapping_entry *level4;
  volatile page_mapping_entry *level3;
  volatile page_mapping_entry *level2;
  volatile page_mapping_entry *level1;

  level4 = (page_mapping_entry *)page_map->address_space_root;
  level3 = get_or_create_level(level4, L4_ID(vaddr));
  level2 = get_or_create_level(level3, L3_ID(vaddr));

  if (flags & VM_FLAGS_PS) {
    volatile page_mapping_entry *entry = &level2[L2_ID(vaddr)];
#ifdef DEBUG
    if (entry->lower != 0) {
      printf("ERROR: Tried mapping page 0x%x to 0x%x (2MB) that is already "
             "mapped @ "
             "entry 0x%x\n",
             vaddr.value, paddr.value, entry);
      while (1)
        ;
    }
#endif

    write_mapping_entry(entry, paddr, flags, disable_execution);
    return;
  }

  level1 = get_or_create_level(level2, L2_ID(vaddr));
  volatile page_mapping_entry *entry = &level1[L1_ID(vaddr)];
#ifdef DEBUG
  if (entry->lower != 0) {
    printf("ERROR: Tried mapping page 0x%x to 0x%x (4KB) that is already "
           "mapped @ "
           "entry 0x%x\n",
           vaddr.value, paddr.value, entry);
    while (1)
      ;
  }
#endif
  write_mapping_entry(entry, paddr, flags, disable_execution);
}

page_map vm_create_address_space() {
  page_map pm;
  u32 pm_entry = (u32)pm_alloc(ARCH_PAGE_SIZE, MMAP_PAGING);
  pm.address_space_root = pm_entry;
  pm.num_levels = 4;
  return pm;
}
