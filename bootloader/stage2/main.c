#include "console.h"
void _cmain(void) {
  u32 x = 2;
  u32 y = 2;
  for (u8 i = 0; i < 255; i++, x++) {
    print_char(x, y, i);
    if(x > 50){
      y += 1;
      x = 2;
    }
  }
  while (1)
    ;
}
