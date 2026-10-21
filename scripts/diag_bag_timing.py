#!/usr/bin/env python3
"""bag 时序体检：找"某几帧位姿倾斜/跳变"的量化证据。

不渲染、不建图，只做四件事：
  1. /livox/imu 与 /livox/lidar 的间隔分布 —— 找出短空洞（<0.2s，gap-fix 抓不到）
  2. 每帧点数 —— 骤降说明那帧是残缺帧（占位帧/丢包）
  3. /aft_mapped_to_init 的 roll/pitch/yaw 逐帧差分 —— 找单帧角度跳变
  4. 把跳变帧和上面的空洞对齐 —— 判断是"数据断"还是"估计发散"

用法:
    python3 scripts/diag_bag_timing.py <bag目录> [--top 15]
"""
import argparse
import math
import sys
from collections import defaultdict

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def quat_to_rpy(x, y, z, w):
    sinr = 2.0 * (w * x + y * z)
    cosr = 1.0 - 2.0 * (x * x + y * y)
    roll = math.atan2(sinr, cosr)
    sinp = 2.0 * (w * y - z * x)
    pitch = math.asin(max(-1.0, min(1.0, sinp)))
    siny = 2.0 * (w * z + x * y)
    cosy = 1.0 - 2.0 * (y * y + z * z)
    yaw = math.atan2(siny, cosy)
    return math.degrees(roll), math.degrees(pitch), math.degrees(yaw)


def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--top", type=int, default=12)
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    msgs = {name: get_message(t) for name, t in types.items()}

    imu_t, lidar_t, lidar_n, odom = [], [], [], []
    while reader.has_next():
        topic, raw, _ = reader.read_next()
        if topic not in msgs:
            continue
        m = deserialize_message(raw, msgs[topic])
        if topic.endswith("/imu"):
            st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
            imu_t.append(st)
        elif topic.endswith("/livox/lidar"):
            st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
            lidar_t.append(st)
            # CustomMsg（livox 自定义格式）用 point_num；PointCloud2 用 width*height
            n = getattr(m, "point_num", None)
            lidar_n.append(int(n) if n is not None else m.width * m.height)
        elif topic.endswith("/aft_mapped_to_init") or topic.endswith("/odom"):
            st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
            p = m.pose.pose.position
            q = m.pose.pose.orientation
            odom.append((st, p.x, p.y, p.z, q.x, q.y, q.z, q.w))

    def gaps(ts):
        return [b - a for a, b in zip(ts, ts[1:])]

    print(f"\n{'='*66}")
    print(f"bag: {args.bag}")
    print(f"{'='*66}")

    for name, ts in (("IMU", imu_t), ("LiDAR", lidar_t), ("ODOM", [o[0] for o in odom])):
        if not ts:
            print(f"{name:6s} 无数据")
            continue
        g = gaps(ts)
        dur = ts[-1] - ts[0]
        print(f"{name:6s} {len(ts):6d} 条  {dur:6.1f}s  "
              f"间隔 p50={pct(g,.5)*1000:.1f} p99={pct(g,.99)*1000:.1f} "
              f"max={max(g)*1000:.1f} ms")

    # ---- IMU 空洞：>3 倍中位间隔才算异常 ----
    g = gaps(imu_t)
    med = pct(g, 0.5) if g else 0
    holes = [(imu_t[i], g[i]) for i in range(len(g)) if g[i] > max(3 * med, 0.04)]
    print(f"\nIMU 短空洞（>{max(3*med,0.04)*1000:.0f} ms）: {len(holes)} 处")
    for t0, d in sorted(holes, key=lambda x: -x[1])[: args.top]:
        print(f"   t={t0 - imu_t[0]:7.2f}s  间隔 {d*1000:6.1f} ms")

    # ---- LiDAR 点数骤降 ----
    if lidar_n:
        med_n = pct(lidar_n, 0.5)
        low = [(i, n) for i, n in enumerate(lidar_n) if n < med_n * 0.5]
        print(f"\nLiDAR 点数中位 {med_n}，不足一半的帧: {len(low)} 个")
        for i, n in low[: args.top]:
            print(f"   t={lidar_t[i] - lidar_t[0]:7.2f}s  {n} 点")

    # ---- 姿态跳变 ----
    if len(odom) > 2:
        rows = []
        for st, x, y, z, qx, qy, qz, qw in odom:
            r, p, ya = quat_to_rpy(qx, qy, qz, qw)
            rows.append((st, x, y, z, r, p, ya))
        jumps = []
        for a, b in zip(rows, rows[1:]):
            dt = b[0] - a[0]
            dr, dp = b[4] - a[4], b[5] - a[5]
            dy = (b[6] - a[6] + 180) % 360 - 180
            dist = math.dist(a[1:4], b[1:4])
            ang = max(abs(dr), abs(dp))
            # yaw 也必须查：地图俯视图上"整块转了个角度"就是 yaw 漂移，
            # 而 roll/pitch 判据完全看不见它（10 Hz 下正常转身可达 9°/帧，
            # 所以 yaw 用更宽的阈值，靠"相对邻域"判断突变）。
            if ang > 2.0 or dist > 0.15 or abs(dy) > 12.0:
                jumps.append((b[0] - rows[0][0], dt, dr, dp, dy, dist))
        print(f"\n姿态/位移突变帧（|Δroll|/|Δpitch|>2°、|Δyaw|>12° 或 单帧位移>0.15m）: {len(jumps)} 处")
        for t, dt, dr, dp, dy, dist in sorted(jumps, key=lambda x: -max(abs(x[2]), abs(x[3])))[: args.top]:
            print(f"   t={t:7.2f}s dt={dt*1000:5.0f}ms  Δroll={dr:+6.2f}° "
                  f"Δpitch={dp:+6.2f}° Δyaw={dy:+7.2f}°  位移={dist:.3f} m")

        print("\n单帧 |Δyaw| 最大的 8 帧（判断 yaw 是否被掰过）:")
        yaws = []
        for a, b in zip(rows, rows[1:]):
            yaws.append((b[0] - rows[0][0], (b[6] - a[6] + 180) % 360 - 180))
        for tt, dv in sorted(yaws, key=lambda x: -abs(x[1]))[:8]:
            print(f"   t={tt:7.2f}s  Δyaw={dv:+7.2f}°  ({abs(dv)*10:.0f} °/s)")

        # 相邻帧角速度，看完工后有没有"来回摆"
        rp = [(b[4], b[5]) for b in rows]
        swing = 0
        for i in range(1, len(rp) - 1):
            if abs(rp[i][0] - rp[i - 1][0]) > 2 and abs(rp[i][0] - rp[i + 1][0]) > 2:
                swing += 1
        print(f"\n单帧孤立跳变后下一帧回弹（典型倾斜帧）: {swing} 次")

    # ---- 时间基准是否一致 ----
    if imu_t and lidar_t:
        off = lidar_t[0] - imu_t[0]
        print(f"\nLiDAR 与 IMU 首帧时间差: {off*1000:+.1f} ms（同一主时钟应 <50 ms）")


if __name__ == "__main__":
    sys.exit(main())
