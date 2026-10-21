"""把 kf/ 目录装配成 nerfstudio 能直接吃的数据集（B4 环节）。

输入（sim_edge_loop.py 的产物）：
    kf/index.json + kf/000001/{image.jpg,pose.txt,cloud.pcd}

输出：
    <out>/
    ├── images/000001.jpg ...        平铺，供 transforms.json 引用
    ├── transforms.json              c2w 已转 OpenGL 约定
    ├── init.ply                     高斯初始化点云（合并 + 体素降采样）
    └── meta.json                    位姿链与外参版本，复现实验的最低要求

为什么不用 COLMAP：位姿来自 FAST-LIO2，公制、连续、无需 SfM。这正是方案 B
相对纯视觉 3DGS 的核心优势 —— 弱纹理场景不必跑 COLMAP。

用法：
    /usr/bin/python3 tools/sim/build_dataset.py --kf <kf> --out <dataset> --points 200000
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.sim.kf_core import c2w_cv_to_opengl, write_transforms_json  # noqa: E402


def read_pcd_binary(path: str) -> np.ndarray:
    """读 DATA binary 的 PCD，返回 (N,3)。字段偏移按 header 解析，不假设顺序。"""
    with open(path, "rb") as f:
        raw = f.read()
    marker = b"DATA binary\n"
    if marker not in raw:
        raise ValueError(f"{path} 不是 binary PCD")
    head_end = raw.index(marker) + len(marker)
    header = raw[:head_end].decode("ascii", errors="ignore")

    fields, sizes, types, counts = [], [], [], []
    for line in header.splitlines():
        k, _, v = line.partition(" ")
        if k == "FIELDS":
            fields = v.split()
        elif k == "SIZE":
            sizes = [int(x) for x in v.split()]
        elif k == "TYPE":
            types = [x for x in v.split()]
        elif k == "COUNT":
            counts = [int(x) for x in v.split()]
    if not fields:
        raise ValueError(f"{path} 缺 FIELDS")

    tmap = {"F": "f", "U": "u", "I": "i"}
    dtype = np.dtype([(f, f"{tmap[t]}{s}") for f, s, t in zip(fields, sizes, types)])
    arr = np.frombuffer(raw[head_end:], dtype=dtype)
    return np.stack([arr["x"], arr["y"], arr["z"]], axis=1).astype(np.float32)


def read_pose_txt(path: str) -> np.ndarray:
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            vals = [float(x) for x in line.split()]
            if len(vals) == 4:
                rows.append(vals)
    if len(rows) != 4:
        raise ValueError(f"{path} 应有 4 行 4x4，实得 {len(rows)} 行")
    return np.array(rows, dtype=np.float64)


def voxel_downsample(P: np.ndarray, voxel: float) -> np.ndarray:
    key = np.floor(P / voxel).astype(np.int64)
    _, idx = np.unique(key, axis=0, return_index=True)
    return P[np.sort(idx)]


def downsample_to(P: np.ndarray, target: int) -> np.ndarray:
    if len(P) <= target:
        return P
    lo, hi = 0.005, 2.0
    for _ in range(28):
        mid = (lo + hi) / 2
        if len(voxel_downsample(P, mid)) > target:
            lo = mid
        else:
            hi = mid
    return voxel_downsample(P, hi)


def write_ply(path: str, P: np.ndarray) -> None:
    """binary_little_endian PLY，带一个中性灰色 rgb（高斯初始化用不到颜色，
    但部分查看器缺 rgb 会渲染成黑色，反而让人以为点云是空的）。"""
    n = len(P)
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {n}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        "end_header\n"
    )
    rec = np.zeros(n, dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
                             ("red", "u1"), ("green", "u1"), ("blue", "u1")])
    rec["x"], rec["y"], rec["z"] = P[:, 0], P[:, 1], P[:, 2]
    rec["red"] = rec["green"] = rec["blue"] = 180
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(rec.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kf", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--points", type=int, default=200000, help="init.ply 目标点数")
    ap.add_argument("--init-voxel", type=float, default=0.0,
                    help=">0 时用固定体素（米）代替自适应点数")
    args = ap.parse_args()

    with open(os.path.join(args.kf, "index.json"), "r", encoding="utf-8") as f:
        idx = json.load(f)
    cam = idx["camera"]
    frames = idx["frames"]
    if not frames:
        raise SystemExit("index.json 里没有关键帧")

    os.makedirs(os.path.join(args.out, "images"), exist_ok=True)

    tjs_frames = []
    clouds = []
    for fr in frames:
        fid = f"{fr['id']:06d}"
        src_img = os.path.join(args.kf, fid, "image.jpg")
        dst_img = os.path.join(args.out, "images", f"{fid}.jpg")
        if not os.path.exists(dst_img):
            os.link(src_img, dst_img) if hasattr(os, "link") else None
            if not os.path.exists(dst_img):
                import shutil
                shutil.copyfile(src_img, dst_img)

        T_cv = read_pose_txt(os.path.join(args.kf, fid, "pose.txt"))
        T_gl = c2w_cv_to_opengl(T_cv)
        tjs_frames.append({
            "file_path": f"images/{fid}.jpg",
            "transform_matrix": T_gl.tolist(),
            "colmap_im_id": fr["id"],
        })

        pcd = os.path.join(args.kf, fid, "cloud.pcd")
        if os.path.exists(pcd):
            clouds.append(read_pcd_binary(pcd))

    if clouds:
        P = np.concatenate(clouds, axis=0)
        before = len(P)
        if args.init_voxel > 0:
            P = voxel_downsample(P, args.init_voxel)
        else:
            P = downsample_to(P, args.points)
    else:
        P = np.zeros((0, 3), dtype=np.float32)
        before = 0
    write_ply(os.path.join(args.out, "init.ply"), P)

    write_transforms_json(
        os.path.join(args.out, "transforms.json"),
        tjs_frames,
        K=np.array([[cam["fx"], 0, cam["cx"]],
                    [0, cam["fy"], cam["cy"]],
                    [0, 0, 1.0]]),
        dist=cam.get("dist", [0, 0, 0, 0]),
        width=cam["width"], height=cam["height"],
        extra={"ply_file_path": "init.ply"},
    )

    meta = {
        "scene": idx.get("scene"),
        "source": idx.get("source"),
        "pose_convention": "opencv_c2w (kf) -> opengl_c2w (transforms.json)",
        "camera": cam,
        "kf_config": idx.get("kf_config"),
        "stats": idx.get("stats"),
        "init_points": int(len(P)),
        "init_points_before_downsample": int(before),
        "T_lidar_cam_version": "GT (synthetic) — real runs must record a checksum here",
        "t_offset_s": 0.0,
    }
    with open(os.path.join(args.out, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"[DS] {len(tjs_frames)} 帧 -> {args.out}")
    print(f"[DS] init.ply: {before} -> {len(P)} 点 ({len(P) * 27 / 1e6:.1f} MB 估算)")
    print(f"[DS] transforms.json / meta.json 已写")


if __name__ == "__main__":
    main()
