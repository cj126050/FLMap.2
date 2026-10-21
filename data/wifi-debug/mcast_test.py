import socket, struct, sys, time

group, port = "239.1.1.1", 9998
mode = sys.argv[1] if len(sys.argv) > 1 else "recv"
iface_ip = sys.argv[2] if len(sys.argv) > 2 else "10.42.0.1"

if mode == "send":
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    for i in range(3):
        s.sendto(b"mc-%d-via-%s" % (i, iface_ip.encode()), (group, port))
        time.sleep(0.3)
    print("sent 3 multicast via %s" % iface_ip, flush=True)
else:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", port))
    mreq = socket.inet_aton(group) + socket.inet_aton(iface_ip)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    s.settimeout(10)
    print("joined %s on %s:%d" % (group, iface_ip, port), flush=True)
    try:
        while True:
            data, addr = s.recvfrom(2048)
            print("got %r from %s" % (data, addr[0]), flush=True)
    except socket.timeout:
        print("timeout, nothing received", flush=True)
