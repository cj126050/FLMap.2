import socket, struct, sys, time

group, port = "239.9.9.9", 9997
mode = sys.argv[1] if len(sys.argv) > 1 else "send"
iface_ip = sys.argv[2] if len(sys.argv) > 2 else None

if mode == "send":
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    if iface_ip:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(iface_ip))
        tag = "explicit:" + iface_ip
    else:
        tag = "default-route"
    for i in range(3):
        s.sendto(("mc-%s-%d" % (tag, i)).encode(), (group, port))
        time.sleep(0.3)
    print("sent via " + tag, flush=True)
else:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", port))
    mreq = socket.inet_aton(group) + socket.inet_aton(iface_ip or "0.0.0.0")
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    s.settimeout(8)
    print("joined %s on %s" % (group, iface_ip or "any"), flush=True)
    try:
        while True:
            data, addr = s.recvfrom(2048)
            print("got %r from %s" % (data, addr[0]), flush=True)
    except socket.timeout:
        print("timeout, nothing received", flush=True)
