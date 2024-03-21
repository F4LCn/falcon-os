#include "console.h"
#include "fs.h"
#include "pmm.h"
#include "string.h"

void _cmain(void) {
  pm_init();
  pm_print();

  fs_init();

  i8 *str = "this is an example";
  i8 *tok = __strtok(str, " ");
  do {
    printf("Tok=%s\n", tok);
  } while ((tok = __strtok(NULL, " ")) != NULL);

  const i8 *config_path = "/BIOS/BOOT/BOOT    CON";
  u8 *config = read_file(config_path);
  printf("config - %s\n", config);

  while (1)
    ;
}
