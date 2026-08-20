"""Raw ADB CNXN handshake against QEMU hostfwd 5555 (M1 acceptance probe)."""
import socket, struct, sys, time

CNXN = 0x4e584e43
A_CNXN = 0x01000000

def adb_msg(cmd, arg0, arg1, payload=b""):
    return struct.pack("<6I", cmd, arg0, arg1, len(payload), 0, 0) + payload

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            break
        buf += c
    return buf

def main():
    host, port = "127.0.0.1", 5555
    ident = b"host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb,fixed_push_symlink_timestamp,abb_exec,remount_shell,track_app,sendrecv_v2,sendrecv_v2_brotli,sendrecv_v2_lz4,sendrecv_v2_zstd,sendrecv_v2_dry_run_send,openscreen_mdns"
    s = socket.create_connection((host, port), timeout=15)
    s.sendall(adb_msg(CNXN, A_CNXN, 4 * 1024 * 1024, ident))
    hdr = recv_exact(s, 24)
    if len(hdr) < 24:
        print(f"NO_VALID_RESPONSE: got {len(hdr)} bytes: {hdr!r}")
        return 1
    cmd, arg0, arg1, dlen, _, magic = struct.unpack("<6I", hdr)
    if cmd == CNXN and magic == cmd ^ 0xFFFFFFFF:
        banner = recv_exact(s, dlen)
        print(f"CNXN OK! banner={banner.decode(errors='replace')!r} version=0x{arg0:x} maxdata={arg1}")
        return 0
    print(f"unexpected msg: cmd=0x{cmd:x} arg0=0x{arg0:x} dlen={dlen}")
    return 1

if __name__ == "__main__":
    sys.exit(main())
