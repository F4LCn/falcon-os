#include "string.h"

u32 __strlen(const i8 *str) {
  i8 *s = (i8 *)str;
  u32 len = 0;
  while (*s++)
    len++;
  return len;
}

void __memcpy(void *dst, const void *src, u32 len) {
  i8 *d = (i8 *)dst;
  i8 *s = (i8 *)src;
  u32 i = 0;
  for (i = 0; i < len / sizeof(u32); ++i) {
    ((u32 *)d)[i] = ((u32 *)s)[i];
  }

  u32 last_offset = i * 4;
  for (i = 0; i < len % sizeof(u32); ++i) {
    d[last_offset] = s[last_offset];
    last_offset++;
  }
}

void __strrev(i8 *str) {
  u32 str_len = __strlen(str);
  for (u32 i = 0; i < str_len / 2; i++) {
    i8 tmp = str[i];
    str[i] = str[str_len - 1 - i];
    str[str_len - 1 - i] = tmp;
  }
}

u32 __itoa(i32 val, i8 *buffer) {
  if (val == 0) {
    buffer[0] = '0';
    buffer[1] = '\0';
    return 1;
  }
  u32 idx = 0;
  if (val < 0) {
    buffer[0] = '-';
    val = -val;
    idx = 1;
  }

  while (val > 0) {
    buffer[idx] = '0' + val % 10;
    val /= 10;
    idx++;
  }
  buffer[idx] = '\0';
  if (buffer[0] == '-') {
    __strrev(buffer + 1);
  } else {
    __strrev(buffer);
  }

  return idx;
}

u32 __htoa(u32 val, i8 *buffer) {
  if (val == 0) {
    buffer[0] = '0';
    buffer[1] = '\0';
    return 1;
  }

  u32 idx = 0;
  u8 remainder;
  while (val > 0) {
    remainder = val % 16;
    if (remainder >= 10) {
      buffer[idx] = 'A' + (remainder - 10);
    } else {
      buffer[idx] = '0' + remainder;
    }
    val /= 16;
    idx++;
  }
  buffer[idx] = '\0';
  __strrev(buffer);
  return idx;
}
