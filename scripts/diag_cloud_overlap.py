#!/usr/bin/env python3
"""逐帧检查 /cloud_registered 的几何一致性，定位"某一帧整体倾斜"。

判据（不需要真值，靠相邻帧的物理连续性）：
  重叠率  帧 i 的点落在帧 i-1 的体素里的比例。10 Hz 慢速移动时应 >40%，
          整帧歪掉的帧会骤降到个位数。
  主轴倾角 帧内点云 PCA 第一主轴与 z 轴的夹角。室内场景主方向通常水平
          （接近 90°），整帧被旋转时这个值会明显偏离邻帧。
  离群点  帧内偏离中位面 >2 m 的点比例，识别"半帧被拉出去"的畸变。

用法: python3 scripts/diag_cloud_overlap.py <bag目录> [--topic /cloud_registered]
"""
import argparse
import sys

import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message


def read_xyz(msg):
    """PointCloud2 -> Nx3 float32。只认 x/y/z，跳过其余字段。"""
    off = {f.name: f.offset for f in msg.fields}
    if not {"x", "y", "z"} <= off.keys():
        return np.empty((0, 3), np.float32)
    n = msg.width * msg.height
    step = msg.point_step
    buf = np.frombuffer(bytes(msg.data), dtype=np.uint8)
    if buf.size < n * step:
        n = buf.size // step
    out = np.empty((n, 3), np.float32)
    for i, k in enumerate("xyz"):
        o = off[k]
        col = buf[: n * step].reshape(n, step)[:, o : o + 4]
        out[:, i] = col.copy().view(np.float32).ravel()
    return out


def voxel_keys(p, res):
    q = np.floor(p / res).astype(np.int64)
    return q


def key_set(p, res):
    q = voxel_keys(p, res)
    return set(map(tuple, q))


def overlap(cur, prev_set, res):
    if not prev_set or len(cur) == 0:
        return 0.0
    q = voxel_keys(cur, res)
    hit = sum(1 for k in map(tuple, q) if k in prev_set)
    return hit / len(q)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bag")
    ap.add_argument("--topic", default="/cloud_registered")
    ap.add_argument("--res", type=float, default=0.20)
    ap.add_argument("--top", type=int, default=12)
    args = ap.parse_args()

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=args.bag, storage_id="sqlite3"),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    if args.topic not in types:
        print(f"bag 里没有 {args.topic}，有的是: {list(types)}")
        return 1
    cls = get_message(types[args.topic])

    rows = []
    prev_pts = None
    prev_set = None
    t0 = None
    while reader.has_next():
        topic, raw, _ = reader.read_next()
        if topic != args.topic:
            continue
        m = deserialize_message(raw, cls)
        st = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        t0 = t0 if t0 is not None else st
        p = read_xyz(m)
        p = p[np.isfinite(p).all(axis=1)]
        if len(p) == 0:
            continue
        # 去地面以下的极端离群点后再算指标，避免单个坏点干扰
        ov = overlap(p, prev_set, args.res)
        r = np.linalg.norm(p - np.median(p, axis=0), axis=1)
        far = float((r > 2.0).mean())
        if len(p) > 50:
            c = p - p.mean(axis=0)
            w, v = np.linalg.eigh(c.T @ c)
            axis = v[:, np.argmax(w)]
            tilt = float(np.degrees(np.arccos(min(1.0, abs(axis[2])))))
        else:
            tilt = float("nan")
        rows.append((st - t0, len(p), ov, tilt, far))
        prev_pts = p
        prev_set = key_set(p, args.res)

    if not rows:
        print("没有读到点云帧")
        return 1

    arr = np.array([[r[0], r[1], r[2], r[3], r[4]] for r in rows])
    t, n, ov, tilt, far = arr.T
    print(f"\n{'='*70}")
    print(f"{args.topic}  {len(rows)} 帧  {t[-1]:.1f}s  体素 {args.res} m")
    print(f"{'='*70}")
    print(f"点数     p10={np.percentile(n,10):.0f} 中位={np.median(n):.0f} p90={np.percentile(n,90):.0f}")
    print(f"重叠率   中位={np.median(ov)*100:.1f}%  p10={np.percentile(ov,10)*100:.1f}% 最低={ov.min()*100:.1f}%")
    print(f"主轴倾角 中位={np.nanmedian(tilt):.1f}°  p90={np.nanpercentile(tilt,90):.1f}° 最大={np.nanmax(tilt):.1f}°")
    print(f"远点占比 中位={np.median(far)*100:.2f}% 最大={far.max()*100:.2f}%")

    # 低重叠帧：整帧错位的强信号
    bad = [(i, t[i], ov[i], tilt[i], far[i]) for i in range(len(t)) if ov[i] < 0.25]
    print(f"\n重叠率 <25% 的帧（整帧错位嫌疑）: {len(bad)} 帧")
    for i, tt, o, ti, fa in bad[: args.top]:
        print(f"   #{i:3d} t={tt:7.2f}s  重叠 {o*100:5.1f}%  倾角 {ti:5.1f}°  远点 {fa*100:.2f}%")

    # 倾角突变：与前后帧均值偏离
    if len(tilt) > 4:
        med = np.nanmedian(tilt)
        dev = np.abs(tilt - med)
        idx = np.argsort(np.nan_to_num(dev))[::-1][: args.top]
        print(f"\n主轴倾角偏离中位({med:.1f}°)最大的帧:")
        for i in sorted(idx):
            print(f"   #{i:3d} t={t[i]:7.2f}s  倾角 {tilt[i]:5.1f}°  偏离 {dev[i]:5.1f}°  重叠 {ov[i]*100:5.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
