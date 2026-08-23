#define SYS_nanosleep 101
#define SYS_exit 93

struct timespec {
    long tv_sec;
    long tv_nsec;
};

static inline long sys2(long n, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    __asm__ __volatile__("svc #0" : "+r"(x0) : "r"(x8), "r"(x1) : "memory");
    return x0;
}

void _start(void) {
    struct timespec ts = { 3600, 0 };
    while (1) {
        sys2(SYS_nanosleep, (long)&ts, 0);
    }
}
