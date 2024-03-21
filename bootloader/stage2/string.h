#ifndef __STRING__
#include "types.h"

u32 __strlen(const i8 *str);
u32 __strncmp(const i8 *s1, const i8 *s2, u32 n);
void __strrev(i8 *str);
void __memcpy(void *dst, const void *src, u32 len);
u32 __itoa(i32 val, i8 *buffer);
u32 __htoa(u32 val, i8 *buffer);
u32 __hltoa(u64 val, i8 *buffer);
i8* __strtok(i8* str, const i8* delim);

#endif // !__STRING__
