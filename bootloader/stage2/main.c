#include "console.h"
#include "pmm.h"
#include "fs.h"

void _cmain(void) {
  pm_init();
  pm_print();

  fs_init();

  while (1)
    ;
}
