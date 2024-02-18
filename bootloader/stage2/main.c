#include "bootinfo.h"
#include "console.h"

void _cmain(void) {
  print("Hello, World\n\tHello Tab\n\t\t:)\n");

  printf("2 + 2 = %d\n", 2 + 2);
  printf("Hello, %s\n", "World. This is a long line");
  u32 a = 12345;
  printf("my pointer address is 0x%x and my value is %d\n", &a, a);

  while (1)
    ;
}
