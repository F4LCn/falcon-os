#ifndef __ASM_HELPER__
#define __ASM_HELPER__
#include "types.h"

void bios_read_sectors(u32 start_sector, u32 dst, u16 count);

#endif
