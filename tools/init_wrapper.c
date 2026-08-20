/*
 * arm64droid init wrapper
 * -----------------------
 * Replaces /init in the appended ramdisk cpio. The real Android first-stage
 * init is moved to /init.orig (same cpio).
 *
 * Why it exists (boot #11 diagnosis):
 *   - CONFIG_IP_PNP is not set      -> kernel "ip=" boot param unavailable
 *   - CONFIG_VIRTIO_NET is not set  -> eth0 only appears after first-stage
 *                                      init loads virtio_net.ko (~2.4s)
 *   - system/vendor are EROFS (RO)  -> cannot inject an rc into a partition
 *   - /second_stage_resources only carries build.prop (hardcoded AOSP)
 *   - the phone image has NO EthernetService/IpClient/DHCP -> nobody brings
 *     eth0 up; real Cuttlefish relies on host-side daemons we don't run.
 *
 * This wrapper forks a child that polls for eth0 and statically configures
 * 10.0.2.15/24 + default gw 10.0.2.2 (QEMU slirp), using raw syscalls only
 * (no libc, no /proc, no device nodes needed — AF_INET socket ioctls).
 * Network state is kernel-global, so it survives every switch_root/pivot
 * that Android init performs afterwards. Parent execs /init.orig immediately.
 */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef long ssize_t;

/* ---------- syscalls (aarch64 asm-generic ABI) ---------- */
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

#define SYS_dup3 24
#define SYS_write 64
#define SYS_read 63
#define SYS_openat 56
#define SYS_close 57
#define SYS_ioctl 29
#define SYS_socket 198
#define SYS_bind 200
#define SYS_listen 201
#define SYS_accept 202
#define SYS_connect 203
#define SYS_setsockopt 208
#define SYS_ppoll 73
#define MSG_DONTWAIT 0x40
#define SYS_mount 40
#define SYS_fchdir 50
#define SYS_chdir 49
#define SYS_chroot 51
#define SYS_dup3 24
#define SYS_mkdirat 34
#define SYS_newfstatat 79
#define SYS_execve 221
#define SYS_clone 220
#define SYS_exit 93
#define SYS_nanosleep 101
#define SYS_clock_gettime 113
#define SYS_rt_sigprocmask 135
#define CLOCK_MONOTONIC 1
#define SIG_BLOCK 0

#define POLLIN 1

#define AT_FDCWD (-100)
#define O_WRONLY 1
#define O_NONBLOCK 2048
#define AF_INET 2
#define SOCK_DGRAM 2
#define SIGCHLD 17
#define CLOCK_REALTIME 0

#define SIOCGIFADDR 0x8915
#define SIOCGIFFLAGS 0x8913
#define SIOCSIFFLAGS 0x8914
#define SIOCSIFADDR 0x8916
#define SIOCSIFNETMASK 0x891c
#define SIOCGIFINDEX 0x8933
#define SIOCGIFNAME 0x8910
#define SIOCADDRT 0x890b

#define IFF_UP 0x1
#define RTF_UP 0x1
#define RTF_GATEWAY 0x2

/* ---------- structs (Linux uapi) ---------- */
struct sockaddr {
    u16 sa_family;
    char sa_data[14];
};
struct sockaddr_in {
    u16 sin_family;
    u16 sin_port;      /* network order, we use 0 */
    u32 sin_addr;      /* network order */
    char sin_zero[8];
};
struct ifreq {
    char ifr_name[16];
    union {
        struct sockaddr ifr_addr;
        struct sockaddr ifr_netmask;
        short ifr_flags;
        int ifr_ifindex;
    } u;
};
struct rtentry {
    unsigned long rt_pad1;
    struct sockaddr rt_dst;
    struct sockaddr rt_gateway;
    struct sockaddr rt_genmask;
    short rt_flags;
    short rt_pad2;
    unsigned long rt_pad3;
    void *rt_pad4;
    short rt_metric;
    char *rt_dev;
    unsigned long rt_mtu;
    unsigned long rt_window;
    unsigned short rt_irtt;
};
struct timespec {
    long tv_sec;
    long tv_nsec;
};
struct pollfd {
    int fd;
    short events;
    short revents;
};

/* ---------- helpers ---------- */
static void *memset(void *s, int c, unsigned long n)
{
    unsigned char *p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}
static void *memcpy(void *d, const void *s, unsigned long n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}
static unsigned long strlen(const char *s)
{
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}
static u32 htonl32(u32 x)
{
    return ((x & 0xffu) << 24) | ((x & 0xff00u) << 8) |
           ((x >> 8) & 0xff00u) | ((x >> 24) & 0xffu);
}

static int kfd = -1; /* /dev/kmsg once it exists */

/* serial tee: /dev/kmsg ring overflows during Android spam (boot #31: blind
 * after t=22s), so ALSO write every log line straight to the PL011 console.
 * Boot #33 observability fix. */
static int serial_fd = -1;
static void serial_tee_open(void)
{
    if (serial_fd >= 0) return;
    serial_fd = (int)sys4(SYS_openat, AT_FDCWD, (long)"/dev/ttyAMA0",
                          O_WRONLY | O_NONBLOCK, 0);
}
static void serial_tee(const char *buf, long len)
{
    if (serial_fd >= 0) sys3(SYS_write, serial_fd, (long)buf, len);
}

static void klog(const char *msg)
{
    serial_tee(msg, (long)strlen(msg));
    if (kfd < 0) return;
    sys3(SYS_write, kfd, (long)msg, (long)strlen(msg));
}

static void klog_num(const char *msg, long v);
static long mono_ms(void);

static void msleep(long ms)
{
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    long r = sys2(SYS_nanosleep, (long)&ts, 0);
    if (r == 0) return;
    static long reported;
    if (reported++ < 3) {
        klog_num("arm64droid-init: nanosleep rc=", r);
        klog_num("arm64droid-init:   ts.sec=", ts.tv_sec);
        klog_num("arm64droid-init:   ts.nsec=", ts.tv_nsec);
    }
    if (r == -4) { /* EINTR: kernel wrote remaining time back into ts */
        sys2(SYS_nanosleep, (long)&ts, 0);
        return;
    }
    /* boots #28-31: nanosleep starts returning -22 at t~2.8s. Fallback:
     * busy-wait on CLOCK_MONOTONIC (clock_gettime never broke). */
    long deadline = mono_ms();
    if (deadline < 0) {
        /* clock broken too: bounded crude spin (~ms order on this guest) */
        volatile unsigned long n = (unsigned long)ms * 20000UL;
        while (n--) { }
        return;
    }
    deadline += ms;
    while (mono_ms() < deadline) { }
}

/* ---------- network configuration ---------- */
static void klog_num(const char *msg, long v)
{
    char buf[96];
    unsigned long ml = strlen(msg);
    memcpy(buf, msg, ml);
    int i = (int)ml;
    unsigned long u;
    if (v < 0) { buf[i++] = '-'; u = (unsigned long)(-v); } else u = (unsigned long)v;
    char tmp[24];
    int j = 0;
    if (u == 0) tmp[j++] = '0';
    while (u) { tmp[j++] = (char)('0' + (int)(u % 10)); u /= 10; }
    while (j) buf[i++] = tmp[--j];
    buf[i++] = '\n';
    buf[i] = 0;
    serial_tee(buf, i);
    if (kfd >= 0) sys3(SYS_write, kfd, (long)buf, i);
}

/* try one full config pass; returns 0 on success, negative errno from the
 * failing ioctl otherwise (step encoded in caller's log) */
static int setup_eth0(int s)
{
    struct ifreq ifr;
    struct sockaddr_in sa;
    long r;

    /* 1. IP address 10.0.2.15 */
    memset(&ifr, 0, sizeof(ifr));
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr = htonl32(0x0a00020f); /* 10.0.2.15 */
    memcpy(ifr.ifr_name, "eth0", 5);
    memcpy(&ifr.u.ifr_addr, &sa, sizeof(sa));
    r = sys3(SYS_ioctl, s, SIOCSIFADDR, (long)&ifr);
    if (r != 0) { klog_num("arm64droid-init: SIOCSIFADDR rc=", r); return 1; }

    /* 2. netmask 255.255.255.0 */
    sa.sin_addr = htonl32(0xffffff00);
    memcpy(&ifr.u.ifr_netmask, &sa, sizeof(sa));
    r = sys3(SYS_ioctl, s, SIOCSIFNETMASK, (long)&ifr);
    if (r != 0) { klog_num("arm64droid-init: SIOCSIFNETMASK rc=", r); return 2; }

    /* 3. bring UP (preserve other flags) */
    r = sys3(SYS_ioctl, s, SIOCGIFFLAGS, (long)&ifr);
    if (r != 0) { klog_num("arm64droid-init: SIOCGIFFLAGS rc=", r); return 3; }
    ifr.u.ifr_flags |= IFF_UP;
    r = sys3(SYS_ioctl, s, SIOCSIFFLAGS, (long)&ifr);
    if (r != 0) { klog_num("arm64droid-init: SIOCSIFFLAGS rc=", r); return 4; }

    /* 4. connected subnet route 10.0.2.0/24 dev eth0. Boot #21 proved the
     * interface is never wiped (flags=0x1043 UP|RUNNING, addr=10.0.2.15) —
     * what gets flushed is the ROUTING TABLE, which drops the auto-added
     * connected route. Without it, the default route fails with ENETUNREACH
     * because the gateway 10.0.2.2 has no route. Add it explicitly. */
    struct rtentry rtsub;
    memset(&rtsub, 0, sizeof(rtsub));
    ((struct sockaddr_in *)&rtsub.rt_dst)->sin_family = AF_INET;
    ((struct sockaddr_in *)&rtsub.rt_dst)->sin_addr = htonl32(0x0a000200);     /* 10.0.2.0 */
    /* rt_gateway stays AF_UNSPEC (all-zero): setting AF_INET here made the
     * kernel treat 0.0.0.0 as a gateway -> lookup failed -> ENETUNREACH.
     * That was the boot #22 bug. */
    ((struct sockaddr_in *)&rtsub.rt_genmask)->sin_family = AF_INET;
    ((struct sockaddr_in *)&rtsub.rt_genmask)->sin_addr = htonl32(0xffffff00); /* /24 */
    rtsub.rt_flags = RTF_UP;
    rtsub.rt_dev = "eth0";
    r = sys3(SYS_ioctl, s, SIOCADDRT, (long)&rtsub);
    if (r != 0 && r != -17 /* EEXIST */) {
        klog_num("arm64droid-init: subnet route rc=", r);   /* log ALL errors now */
    }

    /* 5. default route via 10.0.2.2 */
    struct rtentry rt;
    memset(&rt, 0, sizeof(rt));
    ((struct sockaddr_in *)&rt.rt_dst)->sin_family = AF_INET;      /* 0.0.0.0 = default */
    ((struct sockaddr_in *)&rt.rt_gateway)->sin_family = AF_INET;
    ((struct sockaddr_in *)&rt.rt_gateway)->sin_addr = htonl32(0x0a000202);
    ((struct sockaddr_in *)&rt.rt_genmask)->sin_family = AF_INET;  /* 0.0.0.0 mask = /0 */
    rt.rt_flags = RTF_UP | RTF_GATEWAY;
    rt.rt_dev = "eth0";
    r = sys3(SYS_ioctl, s, SIOCADDRT, (long)&rt);
    if (r != 0 && r != -17 /* EEXIST */) {
        klog_num("arm64droid-init: SIOCADDRT rc=", r);
        /* boot #21 instrumentation: what does eth0 look like NOW?
         * If UP+addr are still set, the ENETUNREACH is a routing/policy
         * issue (netd rules), not a wiped interface. */
        struct ifreq ifr2;
        memset(&ifr2, 0, sizeof(ifr2));
        memcpy(ifr2.ifr_name, "eth0", 5);
        long rf = sys3(SYS_ioctl, s, SIOCGIFFLAGS, (long)&ifr2);
        klog_num("arm64droid-init: post-fail flags=", rf == 0 ? ifr2.u.ifr_flags : rf);
        memset(&ifr2, 0, sizeof(ifr2));
        memcpy(ifr2.ifr_name, "eth0", 5);
        ((struct sockaddr_in *)&ifr2.u.ifr_addr)->sin_family = AF_INET;
        long ra = sys3(SYS_ioctl, s, SIOCGIFADDR, (long)&ifr2);
        klog_num("arm64droid-init: post-fail addr=", ra == 0 ?
                 (long)((struct sockaddr_in *)&ifr2.u.ifr_addr)->sin_addr : ra);
        return 5;
    }

    return 0;
}

/* boot #28-#31 mystery: wrapper never found "eth0" by name, yet netlink
 * showed ifindex 2 alive with routes. Enumerate ALL interfaces by index
 * (SIOCGIFNAME) to reveal the real names. */
static void enum_ifaces(int s)
{
    for (int idx = 1; idx <= 8; idx++) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof(ifr));
        ifr.u.ifr_ifindex = idx;
        long r = sys3(SYS_ioctl, s, SIOCGIFNAME, (long)&ifr);
        if (r == 0) {
            char line[64];
            int i = 0;
            const char *tag = "arm64droid-init: iface ";
            while (*tag) line[i++] = *tag++;
            { char tmp[4]; int j = 0; int u = idx; while (u) { tmp[j++] = (char)('0' + u % 10); u /= 10; } if (!j) tmp[j++] = '0'; while (j) line[i++] = tmp[--j]; }
            line[i++] = '=';
            char *np = ifr.ifr_name;
            while (*np && i < 58) line[i++] = *np++;
            line[i++] = '\n'; line[i] = 0;
            klog(line);
        }
    }
}

/* ---------- time helpers (wall-clock watchdog, boot #30 lesson) ----------
 * Boot #30: iteration-count pacing burned 36000 "500ms" iterations in 51s
 * (nanosleep returned early, reason still instrumented). Never trust the
 * loop counter for timing again — read CLOCK_MONOTONIC. */
static long mono_ms(void)
{
    struct timespec ts;
    if (sys2(SYS_clock_gettime, CLOCK_MONOTONIC, (long)&ts) != 0) return -1;
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* forward decls (defined after child_loop) */
static void diag_probe_gateway(void);
static void diag_dump_state(int s);
static int tcp5555_connect_probe(u32 ip_be, const char *label);
static void echo_setup(void);
static void echo_poll_once(long timeout_ms);
static void nl_setup(void);
static int nl_drain(void);
static void list_dir(const char* path);
static void nl_ifstats(int s);
static int nl_fd;

/* returns 0 if eth0 is configured (probe to gateway gets a live answer),
 * non-zero if the path is broken (ENETUNREACH / timeout). Cheap check
 * used by the watchdog to decide whether to re-apply. */
static int path_alive(void)
{
    int s = (int)sys3(SYS_socket, AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return 1;
    struct sockaddr_in gw;
    memset(&gw, 0, sizeof(gw));
    gw.sin_family = AF_INET;
    gw.sin_port = 0x0100;
    gw.sin_addr = htonl32(0x0a000202);
    long r = sys3(SYS_connect, s, (long)&gw, sizeof(gw));
    int alive = 0;
    if (r == 0) {
        r = sys3(SYS_write, s, (long)"X", 1);
        if (r == 1) {
            struct pollfd pfd = { s, POLLIN, 0 };
            struct timespec ts = { 2, 0 };
            r = sys4(SYS_ppoll, (long)&pfd, 1, (long)&ts, 0);
            if (r > 0) {
                char b;
                r = sys3(SYS_read, s, (long)&b, 1);
                /* -111 ECONNREFUSED (ICMP port-unreach) or data = path alive */
                alive = 1;
            }
        }
    } else if (r == -111 || r == -13) {
        alive = 1; /* refused at connect time still means route exists */
    }
    sys1(SYS_close, s);
    return alive;
}

static void child_loop(void)
{
    if (kfd < 0)
        kfd = (int)sys4(SYS_openat, AT_FDCWD, (long)"/dev/kmsg", 1 | 2048, 0);
    serial_tee_open(); 
    u64 sigset[1] = { ~0ULL }; 
    sys4(SYS_rt_sigprocmask, 0 /* SIG_BLOCK */, (long)sigset, 0, 8);
    long t0 = mono_ms();
    if (t0 < 0) t0 = 0;

    int root_changed = 0;
    long st[16];
    const char *disabled_apex = "/vendor/apex/com.google.cf.disabled.apex";
    const char *bad_apexes[] = {
        "/vendor/apex/com.google.cf.light.apex",
        "/vendor/apex/com.google.cf.oemlock.apex",
        "/vendor/apex/com.google.cf.bt.apex",
        "/vendor/apex/com.google.cf.nfc.apex",
        "/vendor/apex/com.android.hardware.threadnetwork.apex",
        "/vendor/apex/com.android.hardware.uwb.apex",
        0
    };
    int disabled[10] = {0};

    sys3(34 /* SYS_mkdirat */, AT_FDCWD, (long)"/proc", 0755);
    sys5(40 /* SYS_mount */, (long)"proc", (long)"/proc", (long)"proc", 0, 0);

    long last_hb = 0;
    int all_disabled = 0;
    while (1) {
        long now = mono_ms();
        if (now < 0) now = t0; 

        if (!root_changed && (now - t0) > 1000) {
            sys3(34 /* SYS_mkdirat */, AT_FDCWD, (long)"/proc", 0755);
            sys5(40 /* SYS_mount */, (long)"proc", (long)"/proc", (long)"proc", 0, 0);
            int mnt_ns_fd = (int)sys4(SYS_openat, AT_FDCWD, (long)"/proc/1/ns/mnt", 0, 0);
            if (mnt_ns_fd >= 0) {
                long r = sys2(268 /* SYS_setns */, mnt_ns_fd, 0x20000 /* CLONE_NEWNS */);
                if (r == 0) {
                    sys3(34 /* SYS_mkdirat */, AT_FDCWD, (long)"/proc", 0755);
                    sys5(40 /* SYS_mount */, (long)"proc", (long)"/proc", (long)"proc", 0, 0);
                    if (sys4(79 /* SYS_newfstatat */, AT_FDCWD, (long)"/proc/1/root/vendor/apex/com.google.cf.disabled.apex", (long)st, 0) == 0) {
                        long r2 = sys1(SYS_chroot, (long)"/proc/1/root");
                        sys1(SYS_chdir, (long)"/");
                        klog("arm64droid-init: successfully entered real root with /vendor!\n");
                        root_changed = 1;
                    }
                }
                sys1(SYS_close, mnt_ns_fd);
            }
        }

        if (root_changed && !all_disabled) {
            all_disabled = 1;
            for (int i = 0; bad_apexes[i]; i++) {
                if (!disabled[i]) {
                    long r = sys5(40 /* SYS_mount */, (long)disabled_apex, (long)bad_apexes[i], 0, 4096 /* MS_BIND */, 0);
                    if (r == 0) {
                        klog("arm64droid-init: disabled APEX successfully: ");
                        klog(bad_apexes[i]);
                        klog("\n");
                        disabled[i] = 1;
                    } else {
                        all_disabled = 0;
                    }
                }
            }
            if (all_disabled) {
                sys5(40 /* SYS_mount */, (long)"/system/etc/hosts", (long)"/vendor/etc/init/seriallogging.rc", 0, 4096 /* MS_BIND */, 0);
                sys5(40 /* SYS_mount */, (long)"/system/etc/hosts", (long)"/vendor/etc/init/android.hardware.uwb-service.rc", 0, 4096 /* MS_BIND */, 0);
                sys5(40 /* SYS_mount */, (long)"/system/etc/hosts", (long)"/vendor/etc/init/android.hardware.bluetooth-service.rc", 0, 4096 /* MS_BIND */, 0);
                sys5(40 /* SYS_mount */, (long)"/system/etc/hosts", (long)"/vendor/etc/init/android.hardware.radio.data-service.rc", 0, 4096 /* MS_BIND */, 0);
                klog("arm64droid-init: disabled seriallogging and missing HAL rc triggers!\n");
                sys4(33 /* SYS_mknodat */, AT_FDCWD, (long)"/dev/ttyS1", 0666 | 0x2000 /* S_IFCHR */, (1 << 8) | 3 /* /dev/null */);
                sys4(33 /* SYS_mknodat */, AT_FDCWD, (long)"/dev/ttyAMA1", 0666 | 0x2000 /* S_IFCHR */, (204 << 8) | 65 /* ttyAMA1 */);
                sys3(36 /* SYS_symlinkat */, (long)"/dev/block/vda19", AT_FDCWD, (long)"/dev/block/by-name/frp");

                /* Set up IDC files so QEMU Virtio Tablet is recognized as a direct touchscreen */
                sys3(34 /* SYS_mkdirat */, AT_FDCWD, (long)"/vendor/usr", 0755);
                sys5(40 /* SYS_mount */, (long)"tmpfs", (long)"/vendor/usr", (long)"tmpfs", 0, 0);
                sys3(34 /* SYS_mkdirat */, AT_FDCWD, (long)"/vendor/usr/idc", 0755);

                const char idc_data[] = "touch.deviceType = touchScreen\ntouch.orientationAware = 1\n";
                const char *idc_names[] = {
                    "/vendor/usr/idc/QEMU_Virtio_Tablet.idc",
                    "/vendor/usr/idc/Vendor_0627_Product_0003.idc",
                    "/vendor/usr/idc/QEMU_Virtio_Mouse.idc",
                    "/vendor/usr/idc/Vendor_0627_Product_0001.idc",
                    0
                };
                for (int j = 0; idc_names[j]; j++) {
                    int idcfd = (int)sys4(SYS_openat, AT_FDCWD, (long)idc_names[j], 65 /* O_WRONLY|O_CREAT|O_TRUNC */, 0644);
                    if (idcfd >= 0) {
                        sys3(SYS_write, idcfd, (long)idc_data, sizeof(idc_data) - 1);
                        sys1(SYS_close, idcfd);
                    }
                }
                klog("arm64droid-init: created touchscreen IDC files in /vendor/usr/idc!\n");
            }
        }

        if (now - last_hb > 60000) {
            last_hb = now;
            klog("arm64droid-init: watchdog heartbeat\n");
        }

        struct timespec ts = { root_changed ? 2 : 0, root_changed ? 0 : 20000000 }; // 20ms during boot, 2s after switch_root
        sys2(SYS_nanosleep, (long)&ts, 0);
    }
}
/* child stack: 64 KiB */
static char child_stack[65536] __attribute__((aligned(16)));

void _start(void)
{
    /* Clone the watchdog/network child process. 
     * 17 = SIGCHLD */
    long pid = sys5(SYS_clone, 17, (long)(child_stack + sizeof(child_stack)), 0, 0, 0);
    if (pid == 0) {
        child_loop();
        sys1(SYS_exit, 0);
    }
    /* parent: hand over to the real Android first-stage init */
    static const char argv0[] = "/init";
    static const char *const argv[] = { argv0, (const char *)0 };
    sys3(SYS_execve, (long)"/init.orig", (long)argv, 0);
    /* execve failed — nothing sensible left to do */
    klog("arm64droid-init: execve /init.orig failed\n");
    for (;;) msleep(1000);
}
