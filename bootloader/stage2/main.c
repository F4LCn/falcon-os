#include "console.h"
#include "fs.h"
#include "pmm.h"

void _cmain(void) {
  pm_init();
  pm_print();

  fs_init();

  const i8 *config_filename = "BOOT    CON";
  u8 *config = read_file_from_root(config_filename);
  printf("config= %s\n", config);

  while (1)
    ;
}
