#include "console.h"
#include "fs.h"
#include "pmm.h"
#include "string.h"

const i8 *const CONFIG_FILE_PATH = "/SYS/KERNEL  CON";
const i8 *const KERNEL_ENTRY = "KERNEL=";

extern u8 environment[ARCH_PAGE_SIZE];

void load_kernel_environment();
void *load_kernel_file();

void _cmain(void) {
  pm_init();

#ifdef DEBUG
  pm_print();
#endif

  fs_init();

  load_kernel_environment();
  void *kernel_file = load_kernel_file();
  printf("kernel file: %x \n", *((u32 *)kernel_file));

  while (1)
    ;
}

void load_kernel_environment() {
  read_file(CONFIG_FILE_PATH, (void *)&environment);
  printf("config - %s\n", environment);
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
    printf("Found kernel file entry in the config\n");
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

  printf("Loading kernel from path %s\n", kernel_path);

  const file_info kernel_file_info = find_file((const i8 *)kernel_path);

  if (!kernel_file_info.found) {
    printf("PANIC - No kernel file found at %s\n", kernel_path);
    while (1)
      ;
  }

  printf("Found kernel file (SZ=%d, FC=%d)\n", kernel_file_info.size,
         kernel_file_info.first_cluster);

  void *kernel_file = pm_alloc(kernel_file_info.size, MMAP_RECLAIMABLE);
  read_file_from_info(&kernel_file_info, kernel_file);
  return kernel_file;
}
