"""模拟狗端的 B2 环节：数据集 -> 关键帧目录（kf/）。

它替代的是狗上跑的"订阅 /cloud_registered + /camera + /aft_mapped_to_init，
按空间采样存关键帧"那段逻辑。为了让它验证的东西真的能迁移到现场，
这里刻意做了两个约束：

1. **复用 tools/sim/kf_core.py**，与真实端同一份筛选实现（含 EPS 容差、
   阈值语义、位姿 delta 定义）。模拟端另写一套就失去意义。
2. **点云从 depth 反投影再转到世界系**，等价于"完美的 /cloud_registered"。
   也就是说本脚本验证的是下游（位姿链、目录契约、降采样、打包），
   不验证 FAST-LIO2 本身的精度与配准——那部分由真实 bag 单独验。

输出（docs/16 §2.1 的数据契约）：

    <out>/kf/
    ├── 000001/{image.jpg, pose.txt, cloud.pcd}
    ├── 000002/...
    └── index.json

用法：
    /usr/bin/python3 tools/sim/sim_edge_loop.py \
        --scene /path/to/room0 --out /path/to/kf --max-points 15000
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.sim.kf_core import (  # noqa: E402
    KFConfig,
    coverage_report,
    load_poses_txt,
    select_keyframes,
)


def read_meta(scene: str) -> dict:
    p = os.path.join(scene, "meta.json")
    if not os.path.exists(p):
        raise SystemExit(f"缺 meta.json: {p}\n（真实 Replica 数据请先用 tools/sim/dataset_to_bag.py --meta-only 生成）")
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def list_frames(scene: str) -> list[str]:
    res = os.path.join(scene, "results")
    if not os.path.isdir(res):
        raise SystemExit(f"缺 results/ 目录: {res}")
    names = sorted(
        d for d in os.listdir(res)
        if os.path.isdir(os.path.join(res, d)) and d.startswith("frame")
    )
    if not names:
        raise SystemExit(f"{res} 下没有 frameXXXXXX 目录")
    return names


def depth_to_world(depth_png: str, T_c2w: np.ndarray, meta: dict) -> np.ndarray:
    """depth(z-depth, mm) 反投影到世界系，返回 (N,3) float32。

    只保留 [0.15, 25] m 的点：太近的是相机自遮挡，太远的是深度量化噪声，
    真实 FAST-LIO2 的 /cloud_registered 也有类似的量程裁剪。
    """
    d = np.asarray(Image.open(depth_png), dtype=np.float32) / 1000.0
    H, W = d.shape
    fx, fy, cx, cy = meta["fx"], meta["fy"], meta["cx"], meta["cy"]
    u, v = np.meshgrid(np.arange(W), np.arange(H))
    z = d
    ok = (z > 0.15) & (z < 25.0)
    x = (u[ok] - cx) / fx * z[ok]
    y = (v[ok] - cy) / fy * z[ok]
    P_cam = np.stack([x, y, z[ok]], axis=1)
    P_world = P_cam @ T_c2w[:3, :3].T + T_c2w[:3, 3]
    return P_world.astype(np.float32)


def voxel_downsample(P: np.ndarray, voxel: float) -> np.ndarray:
    if len(P) == 0:
        return P
    key = np.floor(P / voxel).astype(np.int64)
    _, idx = np.unique(key, axis=0, return_index=True)
    return P[np.sort(idx)]


def downsample_to(P: np.ndarray, target: int) -> np.ndarray:
    """二分体素尺寸，把点数压到 target 附近（不随机丢弃，保持空间均匀）。"""
    if len(P) <= target:
        return P
    lo, hi = 0.01, 1.0
    for _ in range(24):
        mid = (lo + hi) / 2
        n = len(voxel_downsample(P, mid))
        if n > target:
            lo = mid
        else:
            hi = mid
    out = voxel_downsample(P, hi)
    return out[:target] if len(out) > target else out


def write_pcd_binary(path: str, P: np.ndarray) -> None:
    """与 bag_to_pcd.py 同格式：x y z intensity，float32，binary。"""
    n = len(P)
    arr = np.zeros((n, 4), dtype=np.float32)
    arr[:, :3] = P
    arr[:, 3] = 0.5
    header = (
        "# .PCD v0.7 - Point Cloud Data file format\n"
        "VERSION 0.7\nFIELDS x y z intensity\n"
        "SIZE 4 4 4 4\nTYPE F F F F\nCOUNT 1 1 1 1\n"
        f"WIDTH {n}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\n"
        f"POINTS {n}\nDATA binary\n"
    )
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(arr.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", required=True, help="Replica 格式场景目录（含 results/ traj.txt meta.json）")
    ap.add_argument("--out", required=True, help="输出 kf/ 目录")
    ap.add_argument("--max-points", type=int, default=15000)
    ap.add_argument("--min-trans", type=float, default=0.15)
    ap.add_argument("--min-rot", type=float, default=5.0)
    ap.add_argument("--max-gap", type=float, default=3.0)
    ap.add_argument("--jpeg-quality", type=int, default=90)
    args = ap.parse_args()

    meta = read_meta(args.scene)
    names = list_frames(args.scene)
    poses = load_poses_txt(os.path.join(args.scene, "traj.txt"))
    if len(poses) != len(names):
        raise SystemExit(f"位姿数({len(poses)}) 与帧数({len(names)}) 不一致，数据有问题")

    fps = float(meta.get("fps", 10.0))
    times = [i / fps for i in range(len(poses))]

    cfg = KFConfig(min_trans_m=args.min_trans, min_rot_deg=args.min_rot, max_gap_s=args.max_gap)
    sel = select_keyframes(poses, times, cfg)

    os.makedirs(args.out, exist_ok=True)
    frames_meta = []
    total_pts = 0

    for n, (fi, reason) in enumerate(zip(sel.indices, sel.reasons), start=1):
        sub = os.path.join(args.out, f"{n:06d}")
        os.makedirs(sub, exist_ok=True)

        src = os.path.join(args.scene, "results", names[fi])
        img = Image.open(os.path.join(src, "rgb.png")).convert("RGB")
        img.save(os.path.join(sub, "image.jpg"), quality=args.jpeg_quality)

        with open(os.path.join(sub, "pose.txt"), "w", encoding="utf-8") as f:
            f.write(f"# timestamp {times[fi]:.6f}  frame_index {fi}  reason {reason}\n")
            for r in range(4):
                f.write(" ".join(f"{poses[fi][r, c]:.9f}" for c in range(4)) + "\n")

        P = depth_to_world(os.path.join(src, "depth.png"), poses[fi], meta)
        P = downsample_to(P, args.max_points)
        write_pcd_binary(os.path.join(sub, "cloud.pcd"), P)
        total_pts += len(P)

        frames_meta.append({
            "id": n,
            "src_index": fi,
            "t": round(times[fi], 6),
            "reason": reason,
            "points": int(len(P)),
        })

    stats = coverage_report(poses, times)
    stats.update({
        "frames_total": len(poses),
        "frames_kept": len(sel),
        "keep_ratio": round(len(sel) / max(1, len(poses)), 3),
        "mean_points": round(total_pts / max(1, len(sel))),
    })

    index = {
        "scene": os.path.basename(os.path.abspath(args.scene)),
        "source": meta.get("source", "unknown"),
        "pose_convention": meta.get("pose_convention", "opencv_c2w"),
        "camera": {
            "model": meta.get("camera_model", "PINHOLE"),
            "width": meta["width"], "height": meta["height"],
            "fx": meta["fx"], "fy": meta["fy"], "cx": meta["cx"], "cy": meta["cy"],
            "dist": meta.get("dist", [0, 0, 0, 0]),
        },
        "kf_config": {
            "min_trans_m": args.min_trans, "min_rot_deg": args.min_rot,
            "max_gap_s": args.max_gap, "max_points": args.max_points,
        },
        "stats": stats,
        "frames": frames_meta,
    }
    with open(os.path.join(args.out, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2)

    print(f"[KF] {stats['frames_total']} 帧 -> {stats['frames_kept']} 个关键帧 "
          f"({stats['keep_ratio'] * 100:.1f}%), 平均 {stats['mean_points']} 点")
    print(f"[KF] 轨迹长 {stats['path_m']:.2f} m / {stats['duration_s']:.1f} s, "
          f"朝向覆盖 {stats['yaw_coverage_deg']:.0f} deg")
    print(f"[KF] 输出 {args.out}")


if __name__ == "__main__":
    main()
