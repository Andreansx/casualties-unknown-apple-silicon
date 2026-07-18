#!/usr/bin/env python3
"""udp-probe.py - prove a UDP path works before blaming the game.

The mod's direct-IP transport is plain UDP with no NAT traversal, so a failed join can mean a
broken port-forward, an asymmetric return path (split tunnel), a firewall on the tunnel
interface, or a wrong external->local port mapping - and from inside the game all four look
identical. This isolates the network layer from the game layer.

On the HOST (the side with the forwarded port), with the game NOT running on that port:

    python3 udp-probe.py listen 34960

On the CLIENT:

    python3 udp-probe.py send <host-or-vpn-exit-ip> 34960

An echo means the whole path works - forward, return path, firewall - and any remaining failure
is the game's (most likely the FNV-1a game-hash gate: the Mac port matches the *Windows 7.0.1
demo* plus the same KrokMP build, nothing else).

Silence means the datagrams are not completing the round trip. Run the listener with -v: if it
prints nothing at all, inbound is broken (forward/firewall). If it prints receipts but the sender
still times out, the RETURN path is broken - classic split-tunnel asymmetry, where replies leave
via a different public IP than the one the client has a NAT binding for.
"""
import argparse, socket, sys, time

MAGIC = b"CU-COOP-PROBE "


def listen(port, verbose):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))          # same as LiteNetLib's Start(port): all interfaces
    print(f"listening on 0.0.0.0:{port}/udp - ctrl-c to stop", flush=True)
    n = 0
    while True:
        data, addr = s.recvfrom(2048)
        n += 1
        if verbose or n <= 10:
            print(f"  <- {len(data)}B from {addr[0]}:{addr[1]}  (echoing back)", flush=True)
        s.sendto(data, addr)           # reply from the SAME socket => same 5-tuple as the game


def send(host, port, count, timeout, size):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    pad = b"x" * max(0, size - len(MAGIC) - 8)
    print(f"probing {host}:{port}/udp  ({count} datagrams, {size}B each)", flush=True)
    rtts, lost = [], 0
    for i in range(count):
        payload = MAGIC + str(i).encode().rjust(8, b"0") + pad
        t0 = time.time()
        try:
            s.sendto(payload, (host, port))
            while True:
                data, addr = s.recvfrom(4096)
                if data[:len(MAGIC)] == MAGIC:
                    break
            rtt = (time.time() - t0) * 1000
            rtts.append(rtt)
            print(f"  seq={i} rtt={rtt:.1f}ms from {addr[0]}:{addr[1]}", flush=True)
        except socket.timeout:
            lost += 1
            print(f"  seq={i} TIMEOUT", flush=True)
        time.sleep(0.3)
    print()
    if rtts:
        rtts.sort()
        print(f"RESULT: {len(rtts)}/{count} echoed, loss {lost/count*100:.0f}%  "
              f"min/med/max = {rtts[0]:.1f}/{rtts[len(rtts)//2]:.1f}/{rtts[-1]:.1f} ms")
        print("The UDP path works end to end. A failing join is now the game's problem,")
        print("not the network's - check the game-hash gate first (demo vs full game, mod version).")
        return 0
    print("RESULT: nothing came back.")
    print("  - listener printed NOTHING     -> inbound is broken: port-forward or firewall")
    print("                                    (the tunnel adapter is usually the Public profile)")
    print("  - listener printed receipts    -> the RETURN path is broken: split tunnel means the")
    print("                                    replies egress a different public IP than the one")
    print("                                    your CGNAT has a binding for. Use a full tunnel.")
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    l = sub.add_parser("listen", help="run on the host that owns the forwarded port")
    l.add_argument("port", type=int)
    l.add_argument("-v", "--verbose", action="store_true")
    c = sub.add_parser("send", help="run on the joining client")
    c.add_argument("host")
    c.add_argument("port", type=int)
    c.add_argument("-n", "--count", type=int, default=5)
    c.add_argument("-t", "--timeout", type=float, default=3.0)
    # 1200B stays under a WireGuard/OpenVPN tunnel MTU; raise it to hunt fragmentation blackholes
    c.add_argument("-s", "--size", type=int, default=1200, help="datagram size in bytes")
    a = ap.parse_args()
    try:
        if a.mode == "listen":
            listen(a.port, a.verbose); return 0
        return send(a.host, a.port, a.count, a.timeout, a.size)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
