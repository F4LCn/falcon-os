#include "pmm.h"
#include "bit_math.h"
#include "bootinfo.h"
#include "console.h"

mmap_entry *pm_entries;
u32 pm_entries_count = 0;
bool allocation_enabled = FALSE;

i8 *type_to_str(u32 type) {
  switch (type) {
  case 0:
    return "USED";
  case 1:
    return "FREE";
  case 2:
    return "ACPI";
  case 3:
    return "RECLAIMABLE";
  case 4:
    return "BOOTINFO";
  default:
    return "UNKNOWN";
  }
}

void pm_print() {
  printf("Found %d mmap entries.", pm_entries_count);
  printf("Physical memory map:\n");
  for (u32 i = 0; i < pm_entries_count; ++i) {
    mmap_entry *entry = &pm_entries[i];

    printf("\tMemory region: 0x%X => 0x%X (sz=0x%X) (tp=%s)\n",
           pm_entry_start(entry), pm_entry_end(entry), pm_entry_size(entry),
           type_to_str(pm_entry_type(entry)));
  }
}

void sort_entries() {
  for (u32 i = 0; i < pm_entries_count - 1; ++i) {
    u32 min_idx = i;
    u64 min = pm_entry_start(&pm_entries[i]);
    for (u32 j = i + 1; j < pm_entries_count; ++j) {
      mmap_entry *entry_j = &pm_entries[j];
      if (pm_entry_start(entry_j) < min) {
        min = pm_entry_start(entry_j);
        min_idx = j;
      }
    }

    mmap_entry min_entry = pm_entries[min_idx];
    pm_entries[min_idx] = pm_entries[i];
    pm_entries[i] = min_entry;
  }
}

void sanitize_entries() {
  u32 i, j;

  sort_entries();

  // TODO: check for overlap and resolve

  for (i = 0; i < pm_entries_count - 1; ++i) {
    if (pm_entry_type(&pm_entries[i]) == pm_entry_type(&pm_entries[i + 1]) &&
        pm_entry_end(&pm_entries[i]) == pm_entry_start(&pm_entries[i + 1])) {
      pm_entries[i].size += pm_entries[i + 1].size;
      for (j = i + 1; j < pm_entries_count - 1; ++j) {
        pm_entries[j] = pm_entries[j + 1];
      }
      pm_entries_count--;
      bootinfo.size -= sizeof(mmap_entry);
      i--;
    }
  }
}

void pm_init() {
  pm_entries = &bootinfo.mmap;
  mmap_entry *ptr = pm_entries;
  while ((u32)ptr < (u32)&bootinfo + bootinfo.size) {
    pm_entries_count++;
    ptr++;
  }

  pm_alloc_range(0x0, 0x500, MMAP_USED, TRUE);
  pm_alloc_range((u64)&bootinfo, ARCH_PAGE_SIZE, MMAP_BOOTINFO, TRUE);

  sanitize_entries();
  allocation_enabled = TRUE;
}

bool pm_alloc_from_entry(mmap_entry *entry, u32 alloc_size, u8 type) {
  u64 entry_size = pm_entry_size(entry);
  u64 new_entry_size = entry_size - alloc_size;
  if (new_entry_size == 0) {
    entry->ptr = pm_entry_start(entry) | type;
  } else {
    if (bootinfo.size > ARCH_PAGE_SIZE - sizeof(mmap_entry)) {
      return FALSE;
    }
    mmap_entry *allocated_entry = &pm_entries[pm_entries_count++];
    allocated_entry->ptr = pm_entry_start(entry) | type;
    allocated_entry->size = alloc_size;
    entry->ptr += alloc_size;
    entry->size -= alloc_size;
    sort_entries();
  }
  return TRUE;
}

bool pm_alloc_range(u64 alloc_start, u32 alloc_size, u8 type, bool force) {
  if (alloc_size == 0)
    return TRUE;
  u64 allocation_end = alloc_start + alloc_size;
  for (u32 i = 0; i < pm_entries_count; ++i) {
    mmap_entry *entry = &pm_entries[i];
    if (pm_entry_type(entry) != MMAP_FREE && !force)
      continue;

    if (alloc_start >= pm_entry_start(entry) &&
        alloc_start < pm_entry_end(entry) &&
        allocation_end <= pm_entry_end(entry)) {
      u64 header_size = alloc_start - pm_entry_start(entry);
      u64 footer_size = pm_entry_end(entry) - allocation_end;
      if (header_size == 0 && footer_size == 0) {
        entry->ptr = pm_entry_start(entry) | type;
        return TRUE;
      }

      if (bootinfo.size > ARCH_PAGE_SIZE - sizeof(mmap_entry)) {
        return FALSE;
      }
      mmap_entry *alloc_entry = &pm_entries[pm_entries_count++];
      alloc_entry->ptr = alloc_start | type;
      alloc_entry->size = alloc_size;

      if (footer_size > 0) {
        if (bootinfo.size > ARCH_PAGE_SIZE - sizeof(mmap_entry)) {
          return FALSE;
        }
        mmap_entry *footer_entry = &pm_entries[pm_entries_count++];
        footer_entry->ptr = allocation_end | pm_entry_type(entry);
        footer_entry->size = footer_size;
      }

      if (header_size > 0) {
        entry->size = header_size;
      }

      sort_entries();
      return TRUE;
    }
  }
  return FALSE;
}

void *pm_alloc(u32 size, u8 type) {
  if (!allocation_enabled) {
    printf("Error: allocations are not yet enabled");
    return NULL;
  }
  size = ALIGN_UP(size, ARCH_PAGE_SIZE);
  for (u32 i = 0; i < pm_entries_count; ++i) {
    if (pm_entry_type(&pm_entries[i]) != MMAP_FREE)
      continue;
    u64 aligned_entry_start =
        ALIGN_UP(pm_entry_start(&pm_entries[i]), ARCH_PAGE_SIZE);
    u64 allocation_end = aligned_entry_start + size;
    if (allocation_end > pm_entry_end(&pm_entries[i]))
      continue;
    if (allocation_end > 0xFFFFFFFF) {
      printf("Error: can't address more than 4gb in 32bits mode");
      return NULL;
    }
    void *result = (void *)pm_entry_start(&pm_entries[i]);
    if (!pm_alloc_from_entry(&pm_entries[i], size, type)) {
      printf("Error: could not allocated memory");
    }
    return result;
  }
  return 0;
}
