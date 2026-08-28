// gles_compat.h — minimal stub for builds without GLES decoder
#pragma once

#if GFXSTREAM_ENABLE_HOST_GLES
#error "gles_compat.h stub should not be used with GLES enabled"
#endif

// Provide minimal GL typedefs needed by frame_buffer.h when GLES is disabled
#include <cstdint>

#ifndef GL_TRUE_DEFINED
#define GL_TRUE 1
#define GL_FALSE 0
#endif
