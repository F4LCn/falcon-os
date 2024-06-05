#ifndef __ASM_HELPER__
#define __ASM_HELPER__
#include "types.h"

void bios_read_sectors(u32 start_sector, u32 dst, u16 count);
void switch_long_mode(u32 page_map_addr, u64 kernel_entrypoint);

#endif
