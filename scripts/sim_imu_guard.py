#!/usr/bin/env python3
"""离线验证 imu-guard 的实际效果：按 IMU_Processing.cpp 里的同一套规则
重放 bag 中的 IMU，对比"不设防"和"设防后"的姿态积分结果。

规则与 C++ 实现一一对应：
  - |angvel| > GYRO_SPIKE(8.0 rad/s) 或 |acc|/|mean_acc| > ACC_SPIKE(3.5) 判为异常
  - 异常时先限幅；连续异常 ≤ MAX_HOLD(0.25s) 时 dt 置 0（不积分）；
    超过 0.25s 后按限幅值正常积分
  - 正常采样照常积分

用法: python3 scripts/sim_imu_guard.py <bag目录> [--gyro 8.0] [--acc 3.5]
"""
import argparse
import math
import sys

import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message

GYRO_SPIKE = 8.0
ACC_SPIKE = 3.5
MAX_HOLD = 0.60
G = 9.81


def integrate(frames, guard, gyro_spike, acc_spike, jerk_max=500.0, max_hold=0.25,
              adaptive=True):
    """返回 (总积分角度 rad, 峰值|gyro|, 被拦截帧数)

    jerk_max: 角速度变化率上限 rad/s^2。真实刚体（含人手快速甩动）不超过
    约 500；IMU 尖峰的 5 ms 内跳变等效上千，可无损区分。
    """
    total = 0.0
    peak = 0.0
    blocked = 0
    hold = 0.0
    prev_g = None
    baseline = math.sqrt(frames[0][1]**2 + frames[0][2]**2 + frames[0][3]**2)
    for i in range(len(frames) - 1):
        t0, gx, gy, gz, ax, ay, az = frames[i]
        t1 = frames[i + 1][0]
        dt = t1 - t0
        if dt <= 0 or dt > 0.2:
            continue
        gn = math.sqrt(gx * gx + gy * gy + gz * gz)
        an = math.sqrt(ax * ax + ay * ay + az * az)
        peak = max(peak, gn)
        jerk = 0.0
        if prev_g is not None and dt > 1e-4:
            jerk = math.dist(prev_g, (gx, gy, gz)) / dt
        prev_g = (gx, gy, gz)
        # 自适应阈值：静置 baseline≈0.02 -> 门槛 1.0；行走 baseline≈0.3 -> 门槛 1.8
        # 注意 baseline 只在"判为正常"的帧更新，否则尖峰自己会把门槛顶上去（自污染）
        adap = max(1.0, 6.0 * baseline)
        if guard:
            spike = (gn > gyro_spike or an > acc_spike or jerk > jerk_max
                     or (adaptive and gn > adap))
            if not spike:
                baseline = 0.995 * baseline + 0.005 * gn
            if spike:
                hold += dt
                if hold <= max_hold:
                    blocked += 1
                    continue
                # 超时后按限幅值继续
                if gn > gyro_spike:
                    gn = gyro_spike
            else:
                # 缓慢衰减而非归零：簇内偶有一两帧落回阈值以下时，
                # 不应让保持计数重新开始
                hold = max(0.0, hold - dt * 3.0)
        total += gn * dt
    return total, peak, blocked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--gyro", type=float, default=8.0)
    ap.add_argument("--acc", type=float, default=3.5)
    ap.add_argument("--jerk", type=float, default=500.0)
    ap.add_argument("--hold", type=float, default=MAX_HOLD)
    ap.add_argument("--no-adaptive", action="store_true")
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    topic = next((n for n in types if n.endswith("/imu")), None)
    if topic is None:
        print("没有 IMU 话题")
        return 1
    cls = get_message(types[topic])

    frames = []
    while reader.has_next():
        name, raw, _ = reader.read_next()
        if name != topic:
            continue
        m = deserialize_message(raw, cls)
        st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        g, a = m.angular_velocity, m.linear_acceleration
        frames.append((st, g.x, g.y, g.z, a.x, a.y, a.z))

    frames.sort(key=lambda r: r[0])
    if len(frames) < 10:
        return 1

    t_raw, peak, _ = integrate(frames, guard=False, gyro_spike=args.gyro, acc_spike=args.acc, jerk_max=args.jerk)
    t_grd, _, blocked = integrate(frames, guard=True, gyro_spike=args.gyro, acc_spike=args.acc, jerk_max=args.jerk, max_hold=args.hold, adaptive=not args.no_adaptive)

    print(f"\n{'='*64}")
    print(f"imu-guard 离线验证: {args.bag}")
    print(f"{'='*64}")
    print(f"阈值: |gyro|>{args.gyro} rad/s 或 |acc|>{args.acc}g 或 |dg/dt|>{args.jerk} rad/s^2，最长保持 {args.hold}s")
    print(f"采样: {len(frames)} 帧，时长 {frames[-1][0]-frames[0][0]:.1f}s")
    print()
    # 扣掉静态 bias 引起的正常累积（p50 * 时长），剩下的才是"虚假转角"
    dur = frames[-1][0] - frames[0][0]
    gn_all = sorted(math.sqrt(r[1]**2 + r[2]**2 + r[3]**2) for r in frames)
    bias = gn_all[len(gn_all) // 2]
    base = bias * dur
    print(f"  静态 bias 基线   : {bias:.4f} rad/s，{dur:.1f}s 内正常累积 {math.degrees(base):.0f}°")
    print(f"  不设防虚假转角   : {math.degrees(max(t_raw-base,0)):9.1f}°")
    print(f"  设防后虚假转角   : {math.degrees(max(t_grd-base,0)):9.1f}°")
    den = max(t_raw - base, 1e-9)
    print(f"  抑制掉的虚假转角 : {max(1-(t_grd-base)/den,0)*100:.1f}%")
    print(f"  被拦截的采样     : {blocked} 帧")
    print()
    print(f"  峰值 |gyro|      : {peak:.2f} rad/s = {math.degrees(peak):.0f} °/s")


if __name__ == "__main__":
    sys.exit(main())
