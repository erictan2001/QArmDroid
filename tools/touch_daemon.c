/* touch_daemon.c — zero-latency native touch input for ARM64 Android QEMU guest
 * No libc, no headers — uses raw aarch64 syscalls like init_wrapper.c.
 * Listens on TCP port 6666, writes directly to /dev/input/event1 (virtio-tablet).
 * Multi-client concurrency via fork (clone) per connection.
 *
 * Protocol: fixed 14-byte packets (little-endian):
 *   [cmd:u8] [pad:u8] [x1:u16] [y1:u16] [x2:u16] [y2:u16] [dur:u16] [key:u16]
 * Commands: 1=tap, 2=down, 3=move, 4=up, 5=swipe
 */
typedef unsigned long  u64;
typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;
typedef long           ssize_t;

/* ---- aarch64 syscall ABI ---- */
static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    register long x4 __asm__("x4") = e;
    register long x5 __asm__("x5") = f;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                     : "memory");
    return x0;
}
#define sys5(n,a,b,c,d,e) sys6(n,a,b,c,d,e,0)
#define sys4(n,a,b,c,d)   sys6(n,a,b,c,d,0,0)
#define sys3(n,a,b,c)     sys6(n,a,b,c,0,0,0)
#define sys2(n,a,b)       sys6(n,a,b,0,0,0,0)
#define sys1(n,a)         sys6(n,a,0,0,0,0,0)

/* ---- syscall numbers (aarch64 asm-generic) ---- */
#define SYS_write        64
#define SYS_read         63
#define SYS_openat       56
#define SYS_close        57
#define SYS_ioctl        29
#define SYS_socket       198
#define SYS_bind         200
#define SYS_listen       201
#define SYS_accept       202
#define SYS_setsockopt   208
#define SYS_nanosleep    101
#define SYS_clock_gettime 113
#define SYS_clone        220
#define SYS_exit         93

#define AT_FDCWD   (-100)
#define O_RDWR     2
#define O_WRONLY   1
#define AF_INET    2
#define SOCK_STREAM 1
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define CLOCK_REALTIME 0
#define SIGCHLD    17

/* ---- input event constants (linux/input-event-codes.h) ---- */
#define EV_SYN   0x00
#define EV_KEY   0x01
#define EV_ABS   0x03
#define SYN_REPORT 0
#define ABS_X    0x00
#define ABS_Y    0x01
#define BTN_LEFT   0x110
#define BTN_TOUCH  0x14a

/* EVIOCGNAME(len) = _IOC(_IOC_READ, 'E', 0x06, len) */
#define EVIOCGNAME_128  (((2UL)<<30) | (((u64)'E')<<8) | 0x06 | (128UL<<16))

#define SCREEN_W  1280
#define SCREEN_H  800
#define ABS_MAX   32767

/* ---- structs ---- */
struct sockaddr_in {
    u16 sin_family;
    u16 sin_port;
    u32 sin_addr;
    char sin_zero[8];
};
struct timespec {
    long tv_sec;
    long tv_nsec;
};
struct input_event {
    long tv_sec;
    long tv_usec;
    u16  type;
    u16  code;
    int  value;
};

/* ---- helpers ---- */
void *memset(void *s, int c, unsigned long n) {
    u8 *p = s; while (n--) *p++ = (u8)c; return s;
}
static int strstr_simple(const char *h, const char *needle) {
    for (int i = 0; h[i]; i++) {
        int j = 0;
        while (needle[j] && h[i+j] == needle[j]) j++;
        if (!needle[j]) return 1;
    }
    return 0;
}
static u16 htons16(u16 v) { return (u16)((v >> 8) | (v << 8)); }

/* ---- event I/O ---- */
static int evfd = -1;

static void write_ev(u16 type, u16 code, int value) {
    if (evfd < 0) return;
    struct timespec ts;
    sys2(SYS_clock_gettime, CLOCK_REALTIME, (long)&ts);
    struct input_event ev;
    ev.tv_sec  = ts.tv_sec;
    ev.tv_usec = ts.tv_nsec / 1000;
    ev.type  = type;
    ev.code  = code;
    ev.value = value;
    sys3(SYS_write, evfd, (long)&ev, (long)sizeof(ev));
}
static void syn(void) { write_ev(EV_SYN, SYN_REPORT, 0); }
static void usleep_us(long us) {
    struct timespec ts;
    ts.tv_sec  = us / 1000000;
    ts.tv_nsec = (us % 1000000) * 1000;
    sys2(SYS_nanosleep, (long)&ts, 0);
}

static void ev_down(int x, int y) {
    int ax = (x * ABS_MAX) / SCREEN_W;
    int ay = (y * ABS_MAX) / SCREEN_H;
    write_ev(EV_ABS, ABS_X, ax);
    write_ev(EV_ABS, ABS_Y, ay);
    write_ev(EV_KEY, BTN_TOUCH, 1);
    write_ev(EV_KEY, BTN_LEFT, 1);
    syn();
}
static void ev_move(int x, int y) {
    int ax = (x * ABS_MAX) / SCREEN_W;
    int ay = (y * ABS_MAX) / SCREEN_H;
    write_ev(EV_ABS, ABS_X, ax);
    write_ev(EV_ABS, ABS_Y, ay);
    syn();
}
static void ev_up(void) {
    write_ev(EV_KEY, BTN_TOUCH, 0);
    write_ev(EV_KEY, BTN_LEFT, 0);
    syn();
}
static void ev_tap(int x, int y) {
    ev_down(x, y);
    usleep_us(20000);
    ev_up();
}
static void ev_swipe(int x1, int y1, int x2, int y2, int dur_ms) {
    if (dur_ms <= 0) dur_ms = 200;
    int steps = (dur_ms * 60) / 1000;
    if (steps < 5)  steps = 5;
    if (steps > 60) steps = 60;
    int step_us = (dur_ms * 1000) / steps;
    ev_down(x1, y1);
    for (int i = 1; i <= steps; i++) {
        usleep_us(step_us);
        int cx = x1 + ((x2 - x1) * i) / steps;
        int cy = y1 + ((y2 - y1) * i) / steps;
        ev_move(cx, cy);
    }
    usleep_us(8000);
    ev_up();
}

static void find_device(void) {
    if (evfd >= 0) return;
    char path[] = "/dev/input/event0";
    for (int i = 0; i < 10; i++) {
        path[16] = '0' + (char)i;
        int fd = (int)sys4(SYS_openat, AT_FDCWD, (long)path, O_RDWR, 0);
        if (fd >= 0) {
            char name[128];
            memset(name, 0, 128);
            sys3(SYS_ioctl, fd, EVIOCGNAME_128, (long)name);
            if (strstr_simple(name, "Tablet") || strstr_simple(name, "tablet") || 
                strstr_simple(name, "Touch")  || strstr_simple(name, "touch")  || 
                strstr_simple(name, "Virtio") || strstr_simple(name, "virtio")) {
                evfd = fd;
                return;
            }
            sys1(SYS_close, fd);
        }
    }
    /* fallback to event1 or event0 */
    path[16] = '1';
    evfd = (int)sys4(SYS_openat, AT_FDCWD, (long)path, O_RDWR, 0);
    if (evfd < 0) {
        path[16] = '0';
        evfd = (int)sys4(SYS_openat, AT_FDCWD, (long)path, O_RDWR, 0);
    }
}

void _start(void) {
    int sfd = (int)sys3(SYS_socket, AF_INET, SOCK_STREAM, 0);
    if (sfd < 0) sys1(SYS_exit, 1);

    int one = 1;
    sys5(SYS_setsockopt, sfd, SOL_SOCKET, SO_REUSEADDR, (long)&one, (long)sizeof(int));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons16(6666);
    addr.sin_addr   = 0; /* INADDR_ANY */

    if (sys3(SYS_bind, sfd, (long)&addr, (long)sizeof(addr)) < 0)
        sys1(SYS_exit, 2);
    if (sys2(SYS_listen, sfd, 16) < 0)
        sys1(SYS_exit, 3);

    for (;;) {
        int cfd = (int)sys3(SYS_accept, sfd, 0, 0);
        if (cfd < 0) continue;

        long pid = sys5(SYS_clone, SIGCHLD, 0, 0, 0, 0);
        if (pid == 0) {
            /* Child process: handle this client connection */
            sys1(SYS_close, sfd);
            find_device();

            u8 buf[14];
            for (;;) {
                long total = 0;
                while (total < 14) {
                    long n = sys3(SYS_read, cfd, (long)(buf + total), 14 - total);
                    if (n <= 0) {
                        sys1(SYS_close, cfd);
                        sys1(SYS_exit, 0);
                    }
                    total += n;
                }
                u8  cmd = buf[0];
                u16 x1  = (u16)(buf[2]  | (buf[3]  << 8));
                u16 y1  = (u16)(buf[4]  | (buf[5]  << 8));
                u16 x2  = (u16)(buf[6]  | (buf[7]  << 8));
                u16 y2  = (u16)(buf[8]  | (buf[9]  << 8));
                u16 dur = (u16)(buf[10] | (buf[11] << 8));

                switch (cmd) {
                    case 1: ev_tap(x1, y1); break;
                    case 2: ev_down(x1, y1); break;
                    case 3: ev_move(x1, y1); break;
                    case 4: ev_up(); break;
                    case 5: ev_swipe(x1, y1, x2, y2, dur); break;
                }
            }
        }

        /* Parent process: close client socket and accept next immediately */
        sys1(SYS_close, cfd);
    }
}
