import socket, sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
s.settimeout(12)
print("listening on %d" % port, flush=True)
try:
    while True:
        data, addr = s.recvfrom(2048)
        print("got %r from %s:%d" % (data, addr[0], addr[1]), flush=True)
except socket.timeout:
    print("timeout, nothing received", flush=True)
