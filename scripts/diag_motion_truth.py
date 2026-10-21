#!/usr/bin/env python3
"""判定"IMU 尖峰时刻雷达是否真的动了"——用原始点云（雷达本体系）作真值。

原理：/livox/lidar 是未做任何位姿变换的原始帧。雷达若静止，相邻帧点云
应几乎重合（重叠率高）；若真的被转动，视场内容会整体改变，重叠率骤降。

同时给出帧内质心与主轴角，便于看"是整体转动还是只是噪声"。

用法:
    python3 scripts/diag_motion_truth.py <bag目录> [--t0 12] [--t1 22]
"""
import argparse
import math
import sys

import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message

RES = 0.12  # 体素边长 m


def voxel_set(p, res=RES):
    if len(p) == 0:
        return set()
    q = np.floor(p / res).astype(np.int64)
    return set(map(tuple, q))


def overlap(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / min(len(a), len(b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--t0", type=float, default=None, help="只处理该时刻之后的帧（相对首帧秒）")
    ap.add_argument("--t1", type=float, default=None)
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    lidar_type = types.get("/livox/lidar")
    if lidar_type is None:
        print("bag 里没有 /livox/lidar")
        return 1
    cls = get_message(lidar_type)

    frames = []
    first = None
    while reader.has_next():
        topic, raw, _ = reader.read_next()
        if topic != "/livox/lidar":
            continue
        m = deserialize_message(raw, cls)
        st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        if first is None:
            first = st
        rel = st - first
        if args.t0 is not None and rel < args.t0:
            continue
        if args.t1 is not None and rel > args.t1:
            continue
        pts = np.array([(p.x, p.y, p.z) for p in m.points], dtype=np.float32)
        if len(pts):
            # 去掉无效点（0,0,0）与超远点
            d = np.linalg.norm(pts, axis=1)
            pts = pts[(d > 0.1) & (d < 40.0)]
        frames.append((rel, pts))

    if len(frames) < 2:
        print("窗口内帧数不足")
        return 1

    print(f"\n{'='*72}")
    print(f"原始点云帧间一致性（雷达本体系，体素 {RES} m）: {args.bag}")
    print(f"{'='*72}")
    print(f"{'t(s)':>8} {'点数':>7} {'重叠率':>8} {'质心x':>7} {'质心y':>7} "
          f"{'质心z':>7} {'主轴角°':>8}")

    prev = None
    rows = []
    for rel, pts in frames:
        vs = voxel_set(pts)
        c = pts.mean(axis=0) if len(pts) else np.zeros(3)
        # xz 平面主轴角（雷达系 z 向上时 xz 是水平面；Livox 为 x前/y左/z上）
        ang = float("nan")
        if len(pts) > 200:
            xy = pts[:, :2] - pts[:, :2].mean(axis=0)
            cov = xy.T @ xy / len(xy)
            w, v = np.linalg.eigh(cov)
            ang = math.degrees(math.atan2(v[1, -1], v[0, -1]))
        ov = overlap(prev, vs) if prev is not None else float("nan")
        rows.append(ov)
        print(f"{rel:8.2f} {len(pts):7d} {ov:8.3f} {c[0]:7.3f} {c[1]:7.3f} "
              f"{c[2]:7.3f} {ang:8.1f}")
        prev = vs

    good = [r for r in rows[1:] if not math.isnan(r)]
    if good:
        s = sorted(good)
        print(f"\n重叠率统计: p10={s[len(s)//10]:.3f} p50={s[len(s)//2]:.3f} "
              f"min={min(s):.3f} max={max(s):.3f}")
        low = [i for i, r in enumerate(rows) if not math.isnan(r) and r < 0.35]
        print(f"重叠率 <0.35 的帧（视场剧变，疑似真被转动）: {len(low)} 个")
        for i in low[:12]:
            print(f"    t={frames[i][0]:.2f}s  重叠率={rows[i]:.3f}")


if __name__ == "__main__":
    sys.exit(main())
