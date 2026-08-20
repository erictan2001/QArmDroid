"""Host-side probe for the wrapper's UDP echo service (hostfwd udp 6666).

Decisive test for M1 (boot #27 onward): if this gets an echo, slirp's
hostfwd DOES deliver inbound packets to the guest and the adb timeout is
TCP-specific (firewall / SYN handling). If no echo, slirp inbound delivery
itself is broken (MAC / virtio-net / slirp config)."""
import socket, sys, time

def main():
    host, port = "127.0.0.1", 6666
    payload = b"arm64droid-echo-probe-%d" % int(time.time())
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5.0)
    for attempt in range(3):
        try:
            s.sendto(payload, (host, port))
            data, addr = s.recvfrom(256)
            if data == payload:
                print(f"ECHO OK (attempt {attempt+1}): {data!r} from {addr}")
                return 0
            print(f"ECHO MISMATCH (attempt {attempt+1}): {data!r}")
            return 1
        except socket.timeout:
            print(f"attempt {attempt+1}: timeout")
    print("NO_ECHO: slirp hostfwd inbound delivery broken (or guest echo not up)")
    return 1

if __name__ == "__main__":
    sys.exit(main())
