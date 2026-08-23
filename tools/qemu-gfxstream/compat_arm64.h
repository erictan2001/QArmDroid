// compat_arm64.h — provides x86 intrinsics as no-ops/ARM64 equivalents
// when compiling gfxstream on AArch64 Windows.
#pragma once

#if defined(__aarch64__) || defined(_M_ARM64)
#include <intrin.h>

// ARM64 yield instruction = equivalent of x86 PAUSE
static inline void _mm_pause_impl() { __asm__ volatile("yield"); }

// Override at global scope before any other header includes emmintrin.h
#ifndef _MM_PAUSE_DEFINED
#define _MM_PAUSE_DEFINED
#endif

#endif // __aarch64__
