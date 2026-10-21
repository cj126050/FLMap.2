#!/usr/bin/env python3
"""IMU 原始数据体检：判定"姿态尖峰"是真实运动还是传感器毛刺。

前提：设备静止（雷达平放桌面）时，gyro 应≈0、acc≈1g。
若此时出现大幅尖峰，那就是数据异常，不是外部冲击。

看五件事：
  1. gyro/acc 模长分位数 —— 静态基线到底多干净
  2. 超阈帧是"孤立单帧"还是"连续簇" —— 毛刺的特征是孤立
  3. 尖峰落在哪个轴、多大 —— 单轴爆 = 典型毛刺
  4. 尖峰间隔是否周期性 —— 对应用户说的"每隔若干秒"
  5. IMU dt 分布 —— 重复时间戳会让预积分 dt=0 放大误差

用法:
    python3 scripts/diag_imu_raw.py <bag目录> [--thresh 1.0]
"""
import argparse
import math
import sys
from collections import Counter

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--thresh", type=float, default=1.0, help="gyro 角速度阈值 rad/s")
    ap.add_argument("--top", type=int, default=20)
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    # 只解析 IMU（sensor_msgs/Imu），livox 自定义消息需要源码工作空间，跳过不影响本诊断
    msgs = {}
    for name, t in types.items():
        if not name.endswith("/imu"):
            continue
        try:
            msgs[name] = get_message(t)
        except Exception as e:  # noqa: BLE001
            print(f"跳过 {name} ({t}): {e}")

    imu = []  # (stamp, gx,gy,gz, ax,ay,az)
    while reader.has_next():
        topic, raw, _ = reader.read_next()
        if not topic.endswith("/imu"):
            continue
        m = deserialize_message(raw, msgs[topic])
        st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        g, a = m.angular_velocity, m.linear_acceleration
        imu.append((st, g.x, g.y, g.z, a.x, a.y, a.z))

    if not imu:
        print("bag 里没有 IMU 话题")
        return 1

    imu.sort(key=lambda r: r[0])
    t0 = imu[0][0]
    gnorm = [math.sqrt(r[1] ** 2 + r[2] ** 2 + r[3] ** 2) for r in imu]
    anorm = [math.sqrt(r[4] ** 2 + r[5] ** 2 + r[6] ** 2) for r in imu]

    print(f"\n{'='*70}")
    print(f"bag: {args.bag}")
    print(f"IMU {len(imu)} 条，时长 {imu[-1][0]-t0:.1f}s")
    print(f"{'='*70}")

    # ---- 1. 静态基线 ----
    print("\n[1] 模长分布（rad/s, g）")
    for name, v, unit in (("|gyro|", gnorm, "rad/s"), ("|acc|", anorm, "g")):
        print(f"  {name:7s} p50={pct(v,.5):8.4f} p90={pct(v,.9):8.4f} "
              f"p99={pct(v,.99):8.4f} p999={pct(v,.999):8.4f} max={max(v):8.3f} {unit}")

    # ---- 2/3. 超阈帧 ----
    over = [i for i, v in enumerate(gnorm) if v > args.thresh]
    print(f"\n[2] |gyro| > {args.thresh} rad/s 的帧: {len(over)} 个 "
          f"({len(over)/len(imu)*100:.2f}%)")

    # 连续簇划分
    clusters = []
    if over:
        cur = [over[0]]
        for i in over[1:]:
            if i - cur[-1] <= 2:      # 相邻(≤2帧)算同一簇
                cur.append(i)
            else:
                clusters.append(cur)
                cur = [i]
        clusters.append(cur)
    print(f"    其中孤立/簇共 {len(clusters)} 簇，簇长度分布: "
          f"{dict(sorted(Counter(len(c) for c in clusters).items()))}")

    print(f"\n[3] 最大的 {args.top} 个尖峰（原始分量）")
    print(f"    {'t(s)':>7} {'|gyro|':>8} {'gz?':>7}  "
          f"{'gx':>8} {'gy':>8} {'gz':>8}  {'|acc|':>6} {'簇长':>4}")
    order = sorted(range(len(imu)), key=lambda i: -gnorm[i])[: args.top]
    cl_of = {}
    for ci, c in enumerate(clusters):
        for i in c:
            cl_of[i] = (ci, len(c))
    for i in sorted(order, key=lambda i: imu[i][0]):
        r = imu[i]
        cid, clen = cl_of.get(i, (-1, 0))
        dom = max(range(3), key=lambda k: abs(r[1 + k]))
        axis = "xyz"[dom]
        print(f"    {r[0]-t0:7.2f} {gnorm[i]:8.2f} {axis:>7}  "
              f"{r[1]:8.2f} {r[2]:8.2f} {r[3]:8.2f}  {anorm[i]:6.2f} {clen:4d}")

    # ---- 4. 每个簇的时间范围与积分角度（决定性判据）----
    print(f"\n[4] 每个异常簇的详情（积分角度按 dt 累加）")
    print(f"    {'#':>3} {'起(s)':>7} {'止(s)':>7} {'帧':>4} {'时长(ms)':>9} "
          f"{'峰值|g|':>8} {'积分|角|°':>9} {'acc同爆':>7}")
    for ci, c in enumerate(clusters):
        ts = imu[c[0]][0] - t0, imu[c[-1]][0] - t0
        dur = ts[1] - ts[0]
        integ = 0.0
        for i in c:
            if i + 1 <= c[-1]:
                d = imu[i + 1][0] - imu[i][0]
                integ += gnorm[i] * d
        ahigh = sum(1 for i in c if anorm[i] > 2.0)
        print(f"    {ci:3d} {ts[0]:7.2f} {ts[1]:7.2f} {len(c):4d} {dur*1000:9.1f} "
              f"{max(gnorm[i] for i in c):8.2f} {math.degrees(integ):9.1f} "
              f"{ahigh:3d}/{len(c)}")

    if len(clusters) > 2:
        ct = [imu[c[0]][0] - t0 for c in clusters]
        iv = [b - a for a, b in zip(ct, ct[1:])]
        print(f"    簇起始时刻: {', '.join(f'{x:.1f}' for x in ct)}")
        print(f"    相邻间隔: p50={pct(iv,.5):.2f}s  min={min(iv):.2f}  max={max(iv):.2f}")

    # ---- 5. dt ----
    dt = [b[0] - a[0] for a, b in zip(imu, imu[1:])]
    print(f"\n[5] IMU dt: p50={pct(dt,.5)*1000:.2f} p99={pct(dt,.99)*1000:.2f} "
          f"max={max(dt)*1000:.2f} min={min(dt)*1000:.3f} ms")
    zero = sum(1 for d in dt if d <= 1e-6)
    neg = sum(1 for d in dt if d < 0)
    print(f"    dt<=0 的帧: {zero}，逆序帧: {neg}")

    # ---- 6. 尖峰时刻加速度是否同步异常 ----
    if clusters:
        big = [c for c in clusters if len(c) <= 3]
        acc_spike = [i for c in big for i in c if anorm[i] > 2.0]
        print(f"\n[6] 孤立角速度尖峰 {len(big)} 簇，其中 |acc|>2g 的帧: {len(acc_spike)}")
        print("    （若角速度爆但加速度平静，更像单轴陀螺毛刺，而非真实碰撞）")


if __name__ == "__main__":
    sys.exit(main())
