import socket, struct, time, sys

iface = sys.argv[1] if len(sys.argv) > 1 else "wlp132s0"
dur = float(sys.argv[2]) if len(sys.argv) > 2 else 10

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
s.bind((iface, 0))
s.settimeout(0.5)
end = time.time() + dur
seen = {}
while time.time() < end:
    try:
        pkt = s.recv(2048)
    except socket.timeout:
        continue
    if len(pkt) < 42:
        continue
    ip = pkt[14:]
    if (ip[0] >> 4) != 4 or ip[9] != 17:
        continue
    ihl = (ip[0] & 0xF) * 4
    src = socket.inet_ntoa(ip[12:16])
    dst = socket.inet_ntoa(ip[16:20])
    k = "%s -> %s" % (src, dst)
    seen[k] = seen.get(k, 0) + 1
for k, v in sorted(seen.items(), key=lambda x: -x[1])[:10]:
    print("%4dx %s" % (v, k))
