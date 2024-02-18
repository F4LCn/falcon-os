#ifndef _CONSOLE_
#define _CONSOLE_
#include "bootinfo.h"
#include "types.h"

#include <stdarg.h>

void print(i8* str);
void printf(const i8* format, ...);

#endif
