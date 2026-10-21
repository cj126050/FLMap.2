#!/usr/bin/env python3
"""实时对比 bridge 的输入与输出，判断"某帧倾斜"发生在哪一侧。

同时订阅：
  /cloud_registered   FAST-LIO 原始输出（world 系，2 万点/帧）
  /flmap/cloud        bridge 抽稀后（约 8 千点/帧，经无线到 PC）
逐帧算点数、重叠率、主轴倾角，两边对齐输出。若某帧在输出侧指标骤变、
输入侧正常，问题就在 bridge/传输；两边都变，问题在 LIO。

用法:
  python3 scripts/diag_live_cloud.py --frames 60 [--ref /cloud_registered]
"""
import argparse
import math
import sys

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import PointCloud2


def read_xyz(msg):
    off = {f.name: f.offset for f in msg.fields}
    if not {"x", "y", "z"} <= off.keys():
        return np.empty((0, 3), np.float32)
    n = msg.width * msg.height
    step = msg.point_step
    buf = np.frombuffer(bytes(msg.data), dtype=np.uint8)
    if buf.size < n * step:
        n = buf.size // step
    out = np.empty((n, 3), np.float32)
    flat = buf[: n * step].reshape(n, step)
    for i, k in enumerate("xyz"):
        o = off[k]
        out[:, i] = flat[:, o : o + 4].copy().view(np.float32).ravel()
    return out


class Probe(Node):
    def __init__(self, topics, want):
        super().__init__("cloud_probe")
        self.want = want
        self.data = {t: [] for t in topics}
        qos = QoSProfile(reliability=ReliabilityPolicy.BEST_EFFORT,
                         history=HistoryPolicy.KEEP_LAST, depth=5)
        for t in topics:
            cb = (lambda msg, tt=t: self.on_msg(tt, msg))
            self.create_subscription(PointCloud2, t, cb, qos)
        self.prev = {}

    def on_msg(self, topic, msg):
        if len(self.data[topic]) >= self.want:
            return
        p = read_xyz(msg)
        p = p[np.isfinite(p).all(axis=1)]
        if len(p) < 100:
            return
        st = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        ov = 0.0
        if topic in self.prev:
            prev = self.prev[topic]
            a = set(map(tuple, np.floor(p / 0.2).astype(np.int64)))
            b = set(map(tuple, np.floor(prev / 0.2).astype(np.int64)))
            ov = len(a & b) / max(1, len(a))
        self.prev[topic] = p
        c = p - p.mean(axis=0)
        w, v = np.linalg.eigh(c.T @ c)
        axis = v[:, np.argmax(w)]
        tilt = math.degrees(math.acos(min(1.0, abs(axis[2]))))
        self.data[topic].append((st, len(p), ov, tilt, msg.header.frame_id))
        n = len(self.data[topic])
        if n % 10 == 0:
            print(f"  {topic}: {n}/{self.want} 帧", flush=True)

    def done(self):
        return all(len(v) >= self.want for v in self.data.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--ref", default="/cloud_registered")
    ap.add_argument("--out", default="/flmap/cloud")
    args = ap.parse_args()

    rclpy.init()
    node = Probe([args.ref, args.out], args.frames)
    print(f"等 {args.frames} 帧（{args.ref} + {args.out}）…", flush=True)
    try:
        while rclpy.ok() and not node.done():
            rclpy.spin_once(node, timeout_sec=0.2)
    except KeyboardInterrupt:
        pass

    for topic, rows in node.data.items():
        if not rows:
            print(f"\n{topic}: 没收到数据")
            continue
        ov = np.array([r[2] for r in rows])
        tilt = np.array([r[3] for r in rows])
        n = np.array([r[1] for r in rows])
        t = np.array([r[0] for r in rows])
        dt = np.diff(t)
        print(f"\n{'='*62}\n{topic}  {len(rows)} 帧  frame_id={rows[0][4]}")
        print(f"  点数   {int(n.min())}–{int(n.max())}  中位 {int(np.median(n))}")
        print(f"  间隔   p50={np.median(dt)*1000:.1f}  max={dt.max()*1000:.1f} ms")
        print(f"  重叠   p10={np.percentile(ov,10)*100:.1f}%  中位={np.median(ov)*100:.1f}%")
        print(f"  倾角   中位={np.median(tilt):.1f}°  max={tilt.max():.1f}°")
        bad = [(i, t[i] - t[0], ov[i], tilt[i]) for i in range(len(rows))
               if ov[i] < 0.3 or abs(tilt[i] - np.median(tilt)) > 3]
        print(f"  可疑帧 {len(bad)}:")
        for i, tt, o, ti in bad[:10]:
            print(f"    #{i} t={tt:6.2f}s 重叠 {o*100:5.1f}% 倾角 {ti:5.1f}°")

    node.destroy_node()
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
