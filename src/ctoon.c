#include <stddef.h>
#include <stdint.h>

// Forward declarations of Zig allocator wrappers
extern void* spline_c_alloc(size_t size);
extern void* spline_c_calloc(size_t num, size_t size);
extern void* spline_c_realloc(void *ptr, size_t size);
extern void spline_c_free(void *ptr);

// Redefine standard C library allocators to use Zig-allocated memory
#define malloc spline_c_alloc
#define calloc spline_c_calloc
#define realloc spline_c_realloc
#define free spline_c_free

#define TOON_IMPLEMENTATION
#include "../third-party/ctoon/toon.h"
