#ifndef _ELF_
#define _ELF_
#include "types.h"

#define IDENT_M0 0
#define IDENT_M1 1
#define IDENT_M2 2
#define IDENT_M3 3
#define IDENT_CLASS 4
#define IDENT_DATA 5
#define IDENT_VERSION 6
#define IDENT_ABI 7
#define IDENT_ABIVER 8
#define IDENT_PAD 9
#define IDENT_COUNT 16

#define ELF_MAGIC0 0x7F
#define ELF_MAGIC1 'E'
#define ELF_MAGIC2 'L'
#define ELF_MAGIC3 'F'

#define ELF_MAGIC                                                              \
  ((ELF_MAGIC3 << 24) | (ELF_MAGIC2 << 16) | (ELF_MAGIC1 << 8) | (ELF_MAGIC0))

#define ELF_CLASS_NONE 0
#define ELF_CLASS_32 1
#define ELF_CLASS_64 2

#define ELF_DATA_NONE 0
#define ELF_DATA_LSB 1
#define ELF_DATA_MSB 2

#define ELF_VERSION 1

#define ELF_ABI_NONE 0

#define TYPE_NONE 0
#define TYPE_REL 1
#define TYPE_EXEC 2
#define TYPE_DYN 3
#define TYPE_CORE 4

#define MACHINE_X86_64 62

typedef struct {
  u8 ident[IDENT_COUNT];
  u16 type;
  u16 machine;
  u32 version;
  u64 entry;
  u64 ph_offset;
  u64 sh_offset;
  u32 flags;
  u16 header_size;
  u16 ph_size;
  u16 ph_count;
  u16 sh_size;
  u16 sh_count;
  u16 sh_str_idx;
} elf64_header;

#define PROG_TYPE_NULL 0
#define PROG_TYPE_LOAD 1
#define PROG_TYPE_DYNAMIC 2
#define PROG_TYPE_INTERP 3
#define PROG_TYPE_NOTE 4
#define PROG_TYPE_SHLIB 5
#define PROG_TYPE_PHDR 6
#define PROG_TYPE_TLS 7

typedef struct {
  u32 type;
  u32 flags;
  u64 offset;
  u64 vaddr;
  u64 paddr;
  u64 file_size;
  u64 mem_size;
  u64 align;
} elf64_phdr;

#endif
