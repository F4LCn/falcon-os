#ifndef _PSF_
#define _PSF_
#include "types.h"

#define PSF2_MAGIC0 0x72
#define PSF2_MAGIC1 0xb5
#define PSF2_MAGIC2 0x4a
#define PSF2_MAGIC3 0x86

/* bits used in flags */
#define PSF2_HAS_UNICODE_TABLE 0x01

/* max version recognized so far */
#define PSF2_MAXVERSION 0

/* UTF8 separators */
#define PSF2_SEPARATOR 0xFF
#define PSF2_STARTSEQ 0xFE

struct psf2_header {
  u8 magic[4];
  u32 version;
  u32 headersize; /* offset of bitmaps in file */
  u32 flags;
  u32 length;        /* number of glyphs */
  u32 charsize;      /* number of bytes for each character */
  u32 height, width; /* max dimensions of glyphs */
                     /* charsize = height * ((width + 7) / 8) */
};

typedef struct __attribute((packed)) {
  struct psf2_header header;
  u8 glyphs;
} psf2;

extern u32 _binary__________font_font_psf_start;

#endif
