#include "console.h"
#include "psf.h"
#include "string.h"
#include <stdarg.h>

#define TAB_SIZE 2
#define MAX_BUFFER_SIZE 512

u32 __column = 0;
u32 __line = 0;

void fill() {
  u64 fb = bootinfo.fb_ptr;
  for (u32 j = 0; j < bootinfo.fb_height; ++j) {
    for (u32 i = 0; i < bootinfo.fb_width; ++i) {
      *(u32 *)(fb + i * 4 + j * bootinfo.fb_scanline_bytes) = 0x050505;
    }
  }
}

void print(i8 *str) {
  char *s = str;
  psf2 *font = (psf2 *)&_binary__________font_font_psf_start;
  u64 fb = bootinfo.fb_ptr;
  u32 glyph_width_bytes = (font->header.width + 7) / 8;
  while (*s) {
    if (*s == '\r' && *(s + 1) == '\n')
      s++;
    i8 c = (u8)*s > 0 && (u8)*s < font->header.length ? *s : 0;
    if (c == '\n') {
      __column = 0;
      __line++;
      s++;
      continue;
    } else if (c == '\t') {
      __column += TAB_SIZE;
      s++;
      continue;
    } else {
      u64 current_fb_line =
          fb + __column * font->header.width * 4 +
          __line * font->header.height * bootinfo.fb_scanline_bytes;
      u64 current_fb_pixel = current_fb_line;
      u8 *glyph = (u8 *)(&font->glyphs + c * font->header.charsize);
      u8 *current_line = glyph;
      for (u32 j = 0; j < font->header.height; ++j) {
        u8 mask = 1 << (font->header.width - 1);
        current_fb_pixel = current_fb_line;
        for (u32 i = 0; i < font->header.width; ++i) {
          *(volatile u32 *)(current_fb_pixel) =
              (*current_line & mask) ? 0xFFFFFF : 0;
          mask >>= 1;
          current_fb_pixel += 4;
        }
        current_line += glyph_width_bytes;
        current_fb_line += bootinfo.fb_scanline_bytes;
      }
    }

    s++;
    __column++;
  }
}

u32 vsprintf(i8 *buffer, const i8 *format, va_list ap) {
  i8 *str_arg;
  u32 str_arg_len;
  i32 int_arg;
  u32 uint_arg;
  // i64 long_arg;
  u64 ulong_arg;

  u32 format_len = __strlen(format);
  u32 buffer_idx = 0;
  for (u32 i = 0; i < format_len; ++i) {
    if (format[i] == '%') {
      i++;
      if (format[i] == 's') {
        str_arg = (i8 *)va_arg(ap, char *);
        str_arg_len = __strlen(str_arg);
        __memcpy(buffer + buffer_idx, str_arg, str_arg_len);
        buffer_idx += str_arg_len;
      } else if (format[i] == 'c') {
        buffer[buffer_idx++] = (i8)va_arg(ap, i32);
      } else if (format[i] == 'd') {
        int_arg = (i32)va_arg(ap, i32);
        buffer_idx += __itoa(int_arg, buffer + buffer_idx);
        // } else if (format[i] == 'D') {
        //   long_arg = (i64)va_arg(ap, i64);
        //   buffer_idx += __itoa(long_arg, buffer + buffer_idx);
      } else if (format[i] == 'u') {
        uint_arg = (u32)va_arg(ap, u32);
        buffer_idx += __itoa(uint_arg, buffer + buffer_idx);
        // } else if (format[i] == 'U') {
        //   ulong_arg = (u64)va_arg(ap, u64);
        //   buffer_idx += __itoa(ulong_arg, buffer + buffer_idx);
      } else if (format[i] == 'x') {
        uint_arg = (u32)va_arg(ap, u32);
        buffer_idx += __htoa(uint_arg, buffer + buffer_idx);
        } else if (format[i] == 'X') {
          ulong_arg = (u64)va_arg(ap, u64);
          buffer_idx += __hltoa(ulong_arg, buffer + buffer_idx);
      } else if (format[i] == 'f') {
        // TODO: implement this
      } else {
        buffer[buffer_idx++] = format[i];
      }

    } else {
      buffer[buffer_idx++] = format[i];
    }
  }
  buffer[buffer_idx] = '\0';
  return buffer_idx;
}

void printf(const i8 *format, ...) {
  va_list ap;
  char str_buffer[MAX_BUFFER_SIZE];
  va_start(ap, format);
  vsprintf(str_buffer, format, ap);
  va_end(ap);
  print(str_buffer);
}
