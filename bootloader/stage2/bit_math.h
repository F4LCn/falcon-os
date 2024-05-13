#ifndef __BIT_MATH__
#define __BIT_MATH__

#define ALIGN_UP(x, a) ((((x) + ((a) - 1)) / (a)) * (a))
#define ALIGN_DOWN(x, a) ((((x)) / (a)) * (a))
#define N_UPPER(x, y) (((x) + ((y) - 1)) / (y))

#endif
