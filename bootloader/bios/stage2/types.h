#ifndef _TYPES_
#define _TYPES_

typedef unsigned char u8;
typedef char i8;
typedef unsigned short u16;
typedef short i16;
typedef unsigned int u32;
typedef int i32;
typedef unsigned long long u64;
typedef long long i64;

typedef u8 bool;
#define FALSE 0
#define TRUE 1

#define NULL (void *)0

#define KB(x) ((x) * 1024)
#define MB(x) (KB((x)) * 1024)

#endif // !_TYPES_
