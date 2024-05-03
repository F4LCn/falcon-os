#include "console.h"
#include "elf.h"
#include "fs.h"
#include "pmm.h"
#include "string.h"

const i8 *const CONFIG_FILE_PATH = "/SYS/KERNEL  CON";
const i8 *const KERNEL_ENTRY = "KERNEL=";

extern u8 environment[ARCH_PAGE_SIZE];

void load_kernel_environment();
void *load_kernel_file();
void *load_kernel_executable(void *kernel);

void _cmain(void) {
  pm_init();

#ifdef DEBUG
  pm_print();
#endif

  fs_init();

  load_kernel_environment();
  void *kernel_file = load_kernel_file();
  printf("kernel file: %x \n", *((u32 *)kernel_file));

  void *entrypoint = load_kernel_executable(kernel_file);
  printf("Loaded kernel executable to 0x%x\n", entrypoint);

  while (1)
    ;
}

void load_kernel_environment() {
  read_file(CONFIG_FILE_PATH, (void *)&environment);

#ifdef DEBUG
  printf("config - %s\n", environment);
#endif
}

void *load_kernel_file() {
  u8 *cursor = environment;

  u8 kernel_path[256];

  while (*cursor) {
    if (__strncmp((const i8 *)cursor, KERNEL_ENTRY, __strlen(KERNEL_ENTRY)) !=
        0) {
      while (*cursor != '\n') {
        cursor++;
      }
      cursor++;
      continue;
    }
    break;
  }

  if (*cursor) {

#ifdef DEBUG
    printf("Found kernel file entry in the config\n");
#endif

    cursor += __strlen(KERNEL_ENTRY);
    __memset(kernel_path, 0, 256);
    u32 i = 0;
    while (*cursor && *cursor != ' ' && *cursor != '\n' && *cursor != '\r' &&
           i < 256) {
      kernel_path[i] = *cursor;
      cursor++;
      i++;
    }
    kernel_path[i] = 0;
  }

#ifdef DEBUG
  printf("Loading kernel from path %s\n", kernel_path);
#endif

  const file_info kernel_file_info = find_file((const i8 *)kernel_path);

  if (!kernel_file_info.found) {
    printf("PANIC - No kernel file found at %s\n", kernel_path);
    while (1)
      ;
  }

  printf("INFO: Found kernel file (SZ=%d, FC=%d)\n", kernel_file_info.size,
         kernel_file_info.first_cluster);

  void *kernel_file = pm_alloc(kernel_file_info.size, MMAP_RECLAIMABLE);
  read_file_from_info(&kernel_file_info, kernel_file);
  return kernel_file;
}

void *load_elf(void *kernel) {
  elf64_header *elf_header = (elf64_header *)kernel;
  if (elf_header->ident[IDENT_CLASS] != ELF_CLASS_64) {
    printf("ERROR: unsupported elf class\n");
    while (1)
      ;
  }
  if (elf_header->ident[IDENT_DATA] != ELF_DATA_LSB) {
    printf("ERROR: unsupported elf endianness\n");
    while (1)
      ;
  }
  if (elf_header->machine != MACHINE_X86_64) {
    printf("ERROR: elf file not compiled for x86_64\n");
    while (1)
      ;
  }
  if (elf_header->type != TYPE_EXEC) {
    printf("ERROR: expected an executable elf file\n");
    while (1)
      ;
  }

  // u64 kernel_start_addr = 0;
  // u64 kernel_size = 0;
  void *entrypoint = (void *)elf_header->entry;
  elf64_phdr *program_headers =
      (elf64_phdr *)((u64)kernel + elf_header->ph_offset);
  for (u32 i = 0; i < elf_header->ph_count; ++i) {
    elf64_phdr *phdr = &program_headers[i];
    if (phdr->type != PROG_TYPE_LOAD)
      continue;
    u64 mem_size = phdr->mem_size;

    if (mem_size > MB(64)) {
      printf("ERROR: kernel too big, consider splitting it into modules\n");
      while (1)
        ;
    }

    void *load_addr = pm_alloc((u32)mem_size, MMAP_KERNEL_MODULE);
    if (load_addr == NULL) {
      printf("PANIC: couldn't allocate %d bytes of memory\n", mem_size);
      while (1)
        ;
    }
    void *segment = (void *)((u64)kernel + phdr->offset);
    __memcpy(load_addr, segment, (u32)phdr->file_size);
    u64 bss_size = mem_size - phdr->file_size;
    if (bss_size != 0) {
      void *bss_start = load_addr + phdr->file_size;
      __memset(bss_start, 0, (u32)bss_size);
    }

    // if (kernel_start_addr == 0) {
    //   kernel_start_addr = (u64)load_addr;
    // }
    // kernel_size += mem_size;
  }
  return entrypoint;
}

void *load_kernel_executable(void *kernel) {
  u32 *elf_start = (u32 *)kernel;
  if (*elf_start == ELF_MAGIC) {
    return load_elf(kernel);
  }

  printf("PANIC: unknown kernel format\n");
  while (1)
    ;
}
