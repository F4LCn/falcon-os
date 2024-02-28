#ifndef __PMM__
#include "types.h"
#include "arch/x64.h"

#define PM_PTR_MASK 0xFFFFFFFFFFFFFF00
#define PM_TYPE_MASK 0xFF

#define pm_entry_start(x) ((x)->ptr & PM_PTR_MASK)
#define pm_entry_type(x) ((x)->ptr & PM_TYPE_MASK)
#define pm_entry_size(x) ((x)->size)
#define pm_entry_end(x) (pm_entry_start(x) + pm_entry_size(x))

void pm_init();
void* pm_alloc(u32 size, u8 type);
void pm_print();

#endif
