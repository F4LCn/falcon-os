#include "string.h"
#include "console.h"

u32 __strlen(const i8 *str) {
  i8 *s = (i8 *)str;
  u32 len = 0;
  while (*s++)
    len++;
  return len;
}

u32 __strncmp(const i8 *s1, const i8 *s2, u32 n) {
  for (u32 i = 0; i < n; ++i) {
    if (s1[i] != s2[i]) {
      return (u32)s1[i] - (u32)s2[i];
    }
  }
  return 0;
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
  while (idx < 8) {
    buffer[idx++] = '0';
  }
  buffer[idx] = '\0';
  __strrev(buffer);
  return idx;
}

typedef union {
  u64 u64;
  struct {
    u32 lo;
    u32 hi;
  } u32;
} u64_word;

u32 __hltoa(u64 val, i8 *buffer) {
  u64_word w = {.u64 = val};
  u32 written = 0;
  written += __htoa(w.u32.hi, buffer + written);
  written += __htoa(w.u32.lo, buffer + written);
  return written;
}

i8 *__strtok(i8 *str, const i8 *const delim) {
  static i8 *last_str;
  if (str == NULL && (str = last_str) == NULL) {
    return NULL;
  }

cont:
  for (i8 *dc = (i8 *const)delim; *dc != 0; dc++) {
    if (*str == *dc) {
      str++;
      goto cont;
    }
  }

  if (*str == 0) {
    return NULL;
  }
  i8 *tok = str;

  i8 d = 0;
  for (;;) {
    i8 *str_ptr = str++;
    i8 *delim_ptr = (i8 *)delim;
    do {
      if ((d = *delim_ptr++) == *str_ptr) {
        if (*str_ptr == 0) {
          str = NULL;
        } else {
          str[-1] = 0;
        }
        last_str = str;
        return tok;
      }
    } while (d != 0);
  }
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

void __memset(void *dst, i8 c, u32 len) {
  i8 *d = (i8 *)dst;
  u32 i = 0;
  u32 pattern = (u32)(c << 24 | c << 16 | c << 8 | c);
  for (i = 0; i < len / sizeof(u32); ++i) {
    ((u32 *)d)[i] = pattern;
  }

  u32 last_offset = i * 4;
  for (i = 0; i < len % sizeof(u32); ++i) {
    d[last_offset] = (i8)c;
    last_offset++;
  }
}

// only needed for -O0
// void memcpy(void *d, const void *s, u32 l) { __memcpy(d, s, l); }
// void memset(void *d, i8 c, u32 l) { __memset(d, c, l); }
