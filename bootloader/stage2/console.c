#include "console.h"
#include "psf.h"

void fill() {
  u64 fb = bootinfo.fb_ptr;
  for (u32 j = 0; j < bootinfo.fb_height; ++j) {
    for (u32 i = 0; i < bootinfo.fb_width; ++i) {
      *(u32 *)(fb + i * 4 + j * bootinfo.fb_scanline_bytes) = 0x050505;
    }
  }
}

void print_char(u32 x, u32 y, u8 c) {
  psf2 *font = (psf2 *)&_binary_______font_font_psf_start;
  u64 fb = bootinfo.fb_ptr;
  u8 *glyph = (u8*)(&font->glyphs + c * font->header.charsize);
  u32 glyph_width_bytes = (font->header.width + 7) / 8;
  u64 current_fb_line = fb + x * font->header.width * 4 + y * font->header.height * bootinfo.fb_scanline_bytes;
  u64 current_fb_pixel = current_fb_line;
  u8 *current_line = glyph;
  for (u32 j = 0; j < font->header.height; ++j) {
    u8 mask = 1 << (font->header.width - 1);
    current_fb_pixel = current_fb_line;
    for (u32 i = 0; i < font->header.width; ++i) {
      *(volatile u32 *)(current_fb_pixel) = (*current_line & mask) ? 0xFFFFFF : 0;
      mask >>= 1;
      current_fb_pixel += 4;
    }
    current_line += glyph_width_bytes;
    current_fb_line += bootinfo.fb_scanline_bytes;
  }
}
