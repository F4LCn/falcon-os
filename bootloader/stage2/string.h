#ifndef __STRING__
#include "types.h"

u32 __strlen(const i8* str);
void __strrev(i8* str);
void __memcpy(void* dst, const void* src, u32 len);
u32 __itoa(i32 val, i8* buffer);
u32 __htoa(u32 val, i8* buffer);
u32 __hltoa(u64 val, i8* buffer);

#endif // !__STRING__
