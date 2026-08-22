/*
 * arm64droid guest-side Vulkan passthrough client.
 * ------------------------------------------------
 * Runs INSIDE the Android guest (arm64) via adb shell and drives the host
 * hcs_engine daemon's native Vulkan renderer over TCP (10.0.2.2:6520,
 * the QEMU slirp gateway). This is the proof that the Android emulator
 * can use host-GPU Vulkan through the passthrough daemon.
 *
 * Freestanding aarch64 Linux: raw syscalls only (no libc), same style as
 * tools/init_wrapper.c. Build:
 *
 *   clang --target=aarch64-linux-gnu -ffreestanding -nostdlib \
 *         -fno-stack-protector -fuse-ld=lld "-Wl,-e,_start" \
 *         -o vk_guest_client.elf tools/vk_guest_client.c
 *
 * Run in the guest:
 *   adb push tools/vk_guest_client.elf /data/local/tmp/vk_client
 *   adb shell chmod 755 /data/local/tmp/vk_client
 *   adb shell /data/local/tmp/vk_client 256 256 /data/local/tmp/frame.raw
 *   adb pull /data/local/tmp/frame.raw frame.raw
 *
 * Protocol (see tools/hcs_engine/src/dispatch.rs):
 *   request  = u32 magic 'AVKQ', u32 opcode, u32 seq, u32 plen, payload
 *   response = u32 magic 'AVKA', u32 opcode, u32 seq, i32 status,
 *              u64 handles[4], u32 dlen, detail, u32 datalen, data
 */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef long ssize_t;
typedef long intptr_t;

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

#define SYS_socket 198
#define SYS_connect 203
#define SYS_write 64
#define SYS_read 63
#define SYS_close 57
#define SYS_openat 56
#define SYS_exit 93

#define AF_INET 2
#define SOCK_STREAM 1
#define O_WRONLY 1
#define O_CREAT 64
#define AT_FDCWD (-100)

#define MAGIC_REQ 0x514B5641u  /* 'AVKQ' */
#define MAGIC_RSP 0x41564B41u  /* 'AVKA' */

#define OP_CREATE_INSTANCE 1
#define OP_CREATE_DEVICE 2
#define OP_ALLOCATE_MEMORY 3
#define OP_CREATE_BUFFER 5
#define OP_QUEUE_SUBMIT 6
#define OP_BIND_RENDER_BUFFER 9
#define OP_RENDER_FRAME 10
#define OP_READ_PIXELS 11

struct sockaddr_in {
    u16 sin_family;
    u16 sin_port;
    u32 sin_addr;
    char sin_zero[8];
};

static void *memcpy(void *d, const void *s, unsigned long n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}
static void *memset(void *s, int c, unsigned long n)
{
    unsigned char *p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}
static unsigned long strlen(const char *s)
{
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}
static void itoa(long v, char *buf)
{
    unsigned long u;
    int i = 0, j;
    char tmp[24];
    if (v < 0) { buf[i++] = '-'; u = (unsigned long)(-v); } else u = (unsigned long)v;
    j = 0;
    if (u == 0) tmp[j++] = '0';
    while (u) { tmp[j++] = (char)('0' + (int)(u % 10)); u /= 10; }
    while (j) buf[i++] = tmp[--j];
    buf[i] = 0;
}

static u32 htonl32(u32 x)
{
    return __builtin_bswap32(x);
}
static u16 htons16(u16 x)
{
    return __builtin_bswap16(x);
}

/* write %lu %lu printable */
static void logline(const char *tag, long v, const char *detail)
{
    char buf[160];
    unsigned long i = 0;
    while (*tag && i < sizeof(buf) - 1) buf[i++] = *tag++;
    if (v >= 0) {
        char tmp[24];
        itoa(v, tmp);
        char *t = tmp;
        while (*t && i < sizeof(buf) - 1) buf[i++] = *t++;
    } else {
        const char *m = "(n/a)";
        while (*m && i < sizeof(buf) - 1) buf[i++] = *m++;
    }
    if (detail) {
        while (*detail && i < sizeof(buf) - 1) buf[i++] = *detail++;
    }
    buf[i++] = '\n';
    sys3(SYS_write, 1, (long)buf, i);
}

/* ---------- TCP helpers ---------- */
static int tcp_connect(u32 addr_be /* network order */, u16 port_be)
{
    int s = (int)sys3(SYS_socket, AF_INET, SOCK_STREAM, 0);
    if (s < 0) return s;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = port_be;
    sa.sin_addr = addr_be;
    long r = sys3(SYS_connect, s, (long)&sa, sizeof(sa));
    if (r != 0) {
        sys1(SYS_close, s);
        return -1;
    }
    return s;
}

static int send_all(int fd, const void *buf, unsigned long len)
{
    const char *p = buf;
    while (len > 0) {
        long r = sys3(SYS_write, fd, (long)p, len);
        if (r <= 0) return -1;
        p += r;
        len -= (unsigned long)r;
    }
    return 0;
}

static int recv_all(int fd, void *buf, unsigned long len)
{
    char *p = buf;
    while (len > 0) {
        long r = sys3(SYS_read, fd, (long)p, len);
        if (r <= 0) return -1;
        p += r;
        len -= (unsigned long)r;
    }
    return 0;
}

static u32 rd_u32(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
static u64 rd_u64(const u8 *p)
{
    return (u64)rd_u32(p) | ((u64)rd_u32(p + 4) << 32);
}
static void wr_u32(u8 *p, u32 v)
{
    p[0] = (u8)v; p[1] = (u8)(v >> 8); p[2] = (u8)(v >> 16); p[3] = (u8)(v >> 24);
}
static void wr_u64(u8 *p, u64 v)
{
    wr_u32(p, (u32)v); wr_u32(p + 4, (u32)(v >> 32));
}

static u32 seq_counter;

/* Send one opcode; returns 0 on success and fills out->status/handles/data.
 * payload/plen may be 0/NULL. data_out/data_len receive the binary payload
 * (e.g. rendered pixels) via a caller-provided buffer. */
struct resp {
    u32 status;
    u64 handles[4];
    char detail[256];
    u32 data_len;
    u8 *data;         /* caller-owned, at least data_cap bytes */
    u32 data_cap;
};

static int call(int fd, u32 opcode, const u8 *payload, u32 plen, struct resp *out)
{
    u8 hdr[16];
    wr_u32(hdr, MAGIC_REQ);
    wr_u32(hdr + 4, opcode);
    wr_u32(hdr + 8, ++seq_counter);
    wr_u32(hdr + 12, plen);
    if (send_all(fd, hdr, 16) != 0) return -1;
    if (plen && send_all(fd, payload, plen) != 0) return -1;

    u8 rsp[52];
    if (recv_all(fd, rsp, 52) != 0) return -1;
    u32 magic = rd_u32(rsp);
    u32 op = rd_u32(rsp + 4);
    (void)op;
    u32 seq = rd_u32(rsp + 8);
    (void)seq;
    out->status = rd_u32(rsp + 12);
    out->handles[0] = rd_u64(rsp + 16);
    out->handles[1] = rd_u64(rsp + 24);
    out->handles[2] = rd_u64(rsp + 32);
    out->handles[3] = rd_u64(rsp + 40);
    u32 dlen = rd_u32(rsp + 48);
    if (magic != MAGIC_RSP) return -1;
    if (dlen > sizeof(out->detail) - 1) dlen = sizeof(out->detail) - 1;
    if (dlen && recv_all(fd, out->detail, dlen) != 0) return -1;
    out->detail[dlen] = 0;
    u8 lenb[4];
    if (recv_all(fd, lenb, 4) != 0) return -1;
    out->data_len = rd_u32(lenb);
    if (out->data_len > out->data_cap) out->data_len = out->data_cap;
    if (out->data_len && recv_all(fd, out->data, out->data_len) != 0) return -1;
    return 0;
}

static u8 BUFS[4][64 * 1024];
static u8 frame_buf[512 * 1024];

/* Linux AArch64 entry: kernel does NOT pass argc in x0 — the initial
 * stack holds argc at [sp], argv at [sp+8] (then envp, auxv). Capture sp
 * before any compiler prologue via a naked stub, then jump to vk_main. */
__attribute__((naked)) void _start(void)
{
    __asm__ volatile(
        "mov x0, sp\n\t"
        "b vk_main\n\t");
}

void vk_main(long init_sp)
{
    int rc = 0;
    long argc = *(long *)init_sp;
    char **argv = (char **)(init_sp + 8);
    long w = 256, h = 256;
    if (argc >= 4) {
        w = 0;
        const char *s = argv[1];
        while (*s) { w = w * 10 + (*s - '0'); s++; }
        h = 0;
        s = argv[2];
        while (*s) { h = h * 10 + (*s - '0'); s++; }
    }

    logline("[vk_guest] argc=", argc, 0);
    logline("[vk_guest] width=", w, 0);
    logline("[vk_guest] height=", h, 0);

    int fd = tcp_connect(htonl32(0x0A000202), htons16(6520));
    if (fd < 0) {
        logline("[vk_guest] connect 10.0.2.2:6520 FAILED rc=", fd, 0);
        sys1(SYS_exit, 1);
    }
    logline("[vk_guest] connected to host passthrough daemon", 0, 0);

    struct resp r;
    memset(&r, 0, sizeof(r));
    r.data = frame_buf;
    r.data_cap = sizeof(frame_buf);

    /* 1. CreateInstance */
    if (call(fd, OP_CREATE_INSTANCE, 0, 0, &r) != 0 || r.status != 0) {
        logline("[vk_guest] CreateInstance FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    logline("[vk_guest] CreateInstance ok", 0, 0);

    /* 2. CreateDevice */
    if (call(fd, OP_CREATE_DEVICE, 0, 0, &r) != 0 || r.status != 0) {
        logline("[vk_guest] CreateDevice FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    logline("[vk_guest] CreateDevice ok (device=0x", 0, 0);

    /* 3. CreateBuffer: size u64 @0, usage u32 @8 */
    u32 frame_size = (u32)(w * h * 4);
    u8 *p = BUFS[0];
    wr_u64(p, frame_size);
    wr_u32(p + 8, 0);
    if (call(fd, OP_CREATE_BUFFER, p, 12, &r) != 0 || r.status != 0) {
        logline("[vk_guest] CreateBuffer FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    u64 buffer_handle = r.handles[0];
    logline("[vk_guest] CreateBuffer ok", 0, 0);

    /* 4. AllocateMemory: size u64 @0, flags u32 @8 (bit0 = host-visible) */
    wr_u64(p, frame_size);
    wr_u32(p + 8, 1);
    if (call(fd, OP_ALLOCATE_MEMORY, p, 12, &r) != 0 || r.status != 0) {
        logline("[vk_guest] AllocateMemory FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    u64 memory_handle = r.handles[0];
    logline("[vk_guest] AllocateMemory ok", 0, 0);

    /* 5. BindRenderBuffer: buffer u64 @0, memory u64 @8 */
    wr_u64(p, buffer_handle);
    wr_u64(p + 8, memory_handle);
    if (call(fd, OP_BIND_RENDER_BUFFER, p, 16, &r) != 0 || r.status != 0) {
        logline("[vk_guest] BindRenderBuffer FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    logline("[vk_guest] BindRenderBuffer ok", 0, 0);

    /* 6. RenderFrame: width u32 @0, height u32 @4 */
    wr_u32(p, (u32)w);
    wr_u32(p + 4, (u32)h);
    if (call(fd, OP_RENDER_FRAME, p, 8, &r) != 0 || r.status != 0) {
        logline("[vk_guest] RenderFrame FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    logline("[vk_guest] RenderFrame ok (host GPU dispatched)", 0, 0);

    /* 7. ReadPixels: size u64 @0 */
    wr_u64(p, frame_size);
    if (call(fd, OP_READ_PIXELS, p, 8, &r) != 0 || r.status != 0) {
        logline("[vk_guest] ReadPixels FAILED status=", (long)r.status, r.detail);
        rc = 1; goto out;
    }
    logline("[vk_guest] ReadPixels ok bytes=", (long)r.data_len, 0);

    /* 8. write frame to disk */
    logline("[vk_guest] opening frame file", 0, 0);
    long of = sys4(SYS_openat, AT_FDCWD, (long)argv[3], O_WRONLY | O_CREAT, 0644);
    logline("[vk_guest] openat rc=", of, 0);
    if (of < 0) {
        logline("[vk_guest] open output FAILED rc=", of, 0);
        rc = 1; goto out;
    }
    long wr = 0;
    logline("[vk_guest] writing frame", 0, 0);
    while (wr < (long)r.data_len) {
        long n = sys3(SYS_write, of, (long)(frame_buf + wr), r.data_len - (u32)wr);
        if (n <= 0) break;
        wr += n;
    }
    sys1(SYS_close, of);
    logline("[vk_guest] wrote frame bytes=", wr, 0);

out:
    sys1(SYS_close, fd);
    logline("[vk_guest] done rc=", rc, 0);
    sys1(SYS_exit, rc);
}