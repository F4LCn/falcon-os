#ifndef _VMM_
#define _VMM_

#include "types.h"

// clang-format off
//                     ┏━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━┳━━━┳━━━┳━━━┳━━━┳━━━┳━━━┳━━━┓
//                     ┃63 ┃ 62..52 ┃ 51..48 ┃ 47..12 ┃ 11..8 ┃ 7 ┃ 6 ┃ 5 ┃ 4 ┃ 3 ┃ 2 ┃ 1 ┃ 0 ┃▊
//                     ┣━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━╇━━━╇━━━╇━━━╇━━━╇━━━╇━━━╇━━━┫▊
//                     ┃ X │    A   │   R    │  Page  │   A   │ R │ A │   │ P │ P │ U │ R │   ┃▊
//                     ┃ D │    V   │   S    │Aligned │   V   │ S │ V │ A │ C │ W │ / │ / │ P ┃▊
//                     ┃   │    L   │   V    │  Addr  │   L   │ V │ L │   │ D │ T │ S │ W │   ┃▊
//                     ┗━━━┷━━━━━━━━┷━━━━━━━━┷━━━━━━━━┷━━━━━━━┷━━━┷━━━┷━━━┷━━━┷━━━┷━━━┷━━━┷━━━┛▊
//                       ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
//
//
//              31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
//             ┏━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
//             ┃  ┃                                ┃           ┃                                               ┃▊
//   UPPER     ┃XD┃               IGN              ┃    RSVD   ┃               Upper address bits              ┃▊
//             ┃  ┃                                ┃           ┃                                               ┃▊
//             ┗━━┷━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┷━━━━━━━━━━━┷━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛▊
//               ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
//             ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━┳━━┳━━┳━━┳━━┳━━┳━━┳━━┓
//   LOWER     ┃                                                           ┃           ┃ P┃ I┃  ┃ P┃ P┃ U┃ R┃  ┃▊
//   PD        ┃                      Lower address bits                   ┃     IGN   ┃ S┃ G┃ A┃ C┃ W┃ /┃ /┃ P┃▊
//             ┃                                                           ┃           ┃  ┃ N┃  ┃ D┃ T┃ S┃ W┃  ┃▊
//             ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┷━━━━━━━━━━━┷━━┷━━┷━━┷━━┷━━┷━━┷━━┷━━┛▊
//               ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀








//             ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━┳━━┳━━┳━━┳━━┳━━┳━━┳━━┳━━┓
//   LOWER     ┃                                                           ┃        ┃  ┃ P┃  ┃  ┃ P┃ P┃ U┃ R┃  ┃▊
//   PT        ┃                      Lower address bits                   ┃     IGN┃ G┃ A┃ D┃ A┃ C┃ W┃ /┃ /┃ P┃▊
//             ┃                                                           ┃        ┃  ┃ T┃  ┃  ┃ D┃ T┃ S┃ W┃  ┃▊
//             ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┷━━━━━━━━┷━━┷━━┷━━┷━━┷━━┷━━┷━━┷━━┷━━┛▊
//               ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀

// clang-format on
#define VM_FLAGS_P 1        // Present
#define VM_FLAGS_RW 1 << 1  // Read/Write
#define VM_FLAGS_US 1 << 2  // User/Supervisor
#define VM_FLAGS_PWT 1 << 3 // Page-level write through
#define VM_FLAGS_PCD 1 << 4 // Page-level cache disable
#define VM_FLAGS_A 1 << 5   // Accessed
#define VM_FLAGS_D 1 << 6   // Dirty
#define VM_FLAGS_PS 1 << 7  // Page size
#define VM_FLAGS_G 1 << 8   // Global
#define VM_FLAGS_XD 1 << 31 // Execution disable

#define VM_DEFAULT_FLAGS (VM_FLAGS_P | VM_FLAGS_RW)

// vaddr 64bits
// 63 .. 48 => unused
// 47 .. 39 => PML4 entry
// 38 .. 30 => PDP entry
// 29 .. 21 => PD entry
// 20 .. 12 => PT entry
// 11 .. 00 => page offset

#define LEVEL_ID(x, s, m) (((x.value) >> (s)) & (m))
#define L4_ID(x) LEVEL_ID(x, 39, 0x1ff)
#define L3_ID(x) LEVEL_ID(x, 30, 0x1ff)
#define L2_ID(x) LEVEL_ID(x, 21, 0x1ff)
#define L1_ID(x) LEVEL_ID(x, 12, 0x1ff)
#define PAGE_OFFSET(x) ((x) & 0xfff)

typedef struct {
  u64 value;
} paddr;

typedef struct {
  u64 value;
} vaddr;

typedef struct __attribute((packed)) {
  u32 lower;
  u32 upper;
} page_mapping_entry;

typedef struct {
  u32 address_space_root;
  u8 num_levels;
} page_map;

typedef struct {
  paddr phys_addr;
  vaddr virt_addr;
  u64 length;
} mapping_info;

typedef struct {
#define SEGMENT_MAPPING_COUNT 8
  mapping_info segment_mappings[SEGMENT_MAPPING_COUNT];
  u8 segment_mappings_count;
  u64 entrypoint;
} kernel_info;

page_map vm_create_address_space();
void mmap_to_addr(const page_map *page_map, vaddr vaddr, paddr paddr, u32 flags,
                  bool disable_execution);

#endif
