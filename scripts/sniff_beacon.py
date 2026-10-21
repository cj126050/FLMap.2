#!/usr/bin/env python3
"""在 monitor 接口上统计 802.11 beacon 与 SSID。

用途：判断「PC 热点到底有没有在某个信道上发 beacon」。
狗端 STA 扫描看不到 SSID 时，用它绕过驱动扫描逻辑，直接从物理层数帧。

用法（需 root，接口已设成 monitor）：
    sudo python3 sniff_beacon.py wlan0 8
"""
import collections
import socket
import struct
import sys
import time


def main() -> int:
    dev = sys.argv[1] if len(sys.argv) > 1 else "wlan0"
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0x0003)
    s.bind((dev, 0))
    s.settimeout(0.5)

    beacons = 0
    probes = 0
    total = 0
    ssids = collections.Counter()
    bssids = collections.Counter()

    t0 = time.time()
    while time.time() - t0 < dur:
        try:
            pkt = s.recv(8192)
        except socket.timeout:
            continue
        total += 1
        if len(pkt) < 4:
            continue
        rtlen = struct.unpack("<H", pkt[2:4])[0]
        f = pkt[rtlen:]
        if len(f) < 24:
            continue
        fc = f[0]
        if ((fc >> 2) & 0x3) != 0:      # 只要管理帧
            continue
        sub = (fc >> 4) & 0xF
        if sub not in (5, 8):           # 5=probe response, 8=beacon
            continue
        if sub == 8:
            beacons += 1
        else:
            probes += 1
        bssid = ":".join(f"{b:02x}" for b in f[10:16])
        bssids[bssid] += 1
        # SSID 是第一个 IE（id=0）
        i = 24 + 12
        while i + 2 <= len(f):
            eid, elen = f[i], f[i + 1]
            val = f[i + 2:i + 2 + elen]
            if eid == 0:
                ssids[val.decode("utf-8", "replace")] += 1
                break
            i += 2 + elen

    print(f"监听 {dev} {dur:.0f}s: 总帧 {total}  beacon {beacons}  probe-resp {probes}")
    for name, n in ssids.most_common(12):
        print(f"  SSID={name!r:24s} {n:5d} 次")
    for b, n in bssids.most_common(6):
        print(f"  BSSID={b}  {n} 次")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
