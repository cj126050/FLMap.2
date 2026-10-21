#!/usr/bin/env python3
"""位姿轨迹摘要：按固定时间片打印 xyz/rpy，判断"搬动"还是"估计发散"。

搬动的特征：位姿单向外移，之后在新位置稳定；
估计发散的特征：位姿剧烈来回摆，位置不收敛。

用法: python3 scripts/diag_pose_track.py <bag目录> [--step 0.5] [--t0 0] [--t1 999]
"""
import argparse
import math
import sys

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def quat_to_rpy(x, y, z, w):
    roll = math.atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y))
    pitch = math.asin(max(-1.0, min(1.0, 2.0 * (w * y - z * x))))
    yaw = math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
    return math.degrees(roll), math.degrees(pitch), math.degrees(yaw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--step", type=float, default=0.5)
    ap.add_argument("--t0", type=float, default=0.0)
    ap.add_argument("--t1", type=float, default=1e9)
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    topic = next((n for n in types if n.endswith("/aft_mapped_to_init")), None)
    if topic is None:
        print("没有 /aft_mapped_to_init")
        return 1
    cls = get_message(types[topic])

    rows = []
    while reader.has_next():
        name, raw, _ = reader.read_next()
        if name != topic:
            continue
        m = deserialize_message(raw, cls)
        st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        p, q = m.pose.pose.position, m.pose.pose.orientation
        rows.append((st, p.x, p.y, p.z, *quat_to_rpy(q.x, q.y, q.z, q.w)))

    if not rows:
        return 1
    t0 = rows[0][0]
    print(f"\n{'='*78}")
    print(f"位姿轨迹（每 {args.step}s 采样）: {args.bag}")
    print(f"{'='*78}")
    print(f"{'t(s)':>7} {'x':>8} {'y':>8} {'z':>8} {'roll':>8} {'pitch':>8} {'yaw':>8}")
    nxt = t0 + args.t0
    last = None
    for r in rows:
        if r[0] - t0 < args.t0 or r[0] - t0 > args.t1:
            continue
        if r[0] >= nxt:
            print(f"{r[0]-t0:7.2f} {r[1]:8.3f} {r[2]:8.3f} {r[3]:8.3f} "
                  f"{r[4]:8.2f} {r[5]:8.2f} {r[6]:8.2f}")
            nxt += args.step
            last = r

    first = rows[0]
    fin = rows[-1]
    print(f"\n首帧: pos=({first[1]:.3f},{first[2]:.3f},{first[3]:.3f}) "
          f"rpy=({first[4]:.2f},{first[5]:.2f},{first[6]:.2f})")
    print(f"末帧: pos=({fin[1]:.3f},{fin[2]:.3f},{fin[3]:.3f}) "
          f"rpy=({fin[4]:.2f},{fin[5]:.2f},{fin[6]:.2f})")
    print(f"净位移 {math.dist(first[1:4], fin[1:4]):.3f} m，"
          f"净转角 roll {fin[4]-first[4]:+.2f}° pitch {fin[5]-first[5]:+.2f}° "
          f"yaw {fin[6]-first[6]:+.2f}°")


if __name__ == "__main__":
    sys.exit(main())
