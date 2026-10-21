"""生成一个 Replica 格式的合成房间数据集（L0 级验证用）。

为什么需要它：在没有相机、没有狗的情况下，仍然要验证"目录契约 + 坐标约定 +
关键帧逻辑 + 位姿链"这四件事。合成数据的价值在于 **GT 位姿是已知的**，
任何一步坐标系搞反都会立刻在重投影检查里暴露，而不是等到训练出糊图才发现。

输出结构（与 Replica 官方一致，便于后续换成真实数据时脚本不用改）：

    <out>/room0/
    ├── results/frame000000/rgb.png      8-bit RGB
    ├── results/frame000000/depth.png    16-bit, 单位 mm, z-depth
    ├── traj.txt                         每行 16 个数 = 4x4 c2w（行优先）
    └── meta.json                        内参 + 位姿约定 + 来源标记

位姿约定：**OpenCV c2w**（x 右、y 下、z 前）。Replica 官方是 OpenGL 约定，
换真实数据时由 dataset_to_bag.py 负责转换，本文件不承担这个责任。

用法：
    /usr/bin/python3 tools/sim/make_synthetic.py --out data/sim --frames 120
"""

from __future__ import annotations

import argparse
import json
import os

import numpy as np
from PIL import Image


def look_at_cv(eye: np.ndarray, target: np.ndarray, up=(0.0, 0.0, 1.0)) -> np.ndarray:
    """构造 OpenCV 约定的 c2w：z 轴指向前方，y 轴指向下方。

    x_c = normalize(z_c × up) 得到"右"，y_c = z_c × x_c 得到"下"。
    注意别用 cross(up, z_c)，那给的是"左"——表现是整幅图左右镜像，
    而镜像在单目训练里几乎看不出来，只有投影检查能抓到。
    """
    z_c = target - eye
    z_c = z_c / np.linalg.norm(z_c)
    up = np.asarray(up, dtype=np.float64)
    x_c = np.cross(z_c, up)
    if np.linalg.norm(x_c) < 1e-6:          # 光轴与 up 平行，退化
        x_c = np.array([1.0, 0.0, 0.0])
    x_c /= np.linalg.norm(x_c)
    y_c = np.cross(z_c, x_c)

    T = np.eye(4)
    T[:3, 0], T[:3, 1], T[:3, 2] = x_c, y_c, z_c
    T[:3, 3] = eye
    return T


def render(T_c2w: np.ndarray, room: dict, K: tuple, W: int, H: int):
    """对一个轴对齐盒子内表面做射线求交，返回 (rgb, depth_mm)。

    盒子法向一律朝内，所以只取 t > 0 的最近交点。相机必须位于盒子内部。
    """
    fx, fy, cx, cy = K
    u = (np.arange(W) + 0.5 - cx) / fx
    v = (np.arange(H) + 0.5 - cy) / fy
    d_cam = np.empty((H, W, 3))
    d_cam[..., 0] = u[None, :]
    d_cam[..., 1] = v[:, None]
    d_cam[..., 2] = 1.0                      # 针孔：z 分量恒为 1，故 t 即 z-depth

    R, C = T_c2w[:3, :3], T_c2w[:3, 3]
    d_w = d_cam @ R.T

    x0, x1 = room["x"]
    y0, y1 = room["y"]
    z0, z1 = room["z"]
    # (平面点, 内法向)
    planes = [
        (np.array([x0, 0, 0]), np.array([1.0, 0, 0])),
        (np.array([x1, 0, 0]), np.array([-1.0, 0, 0])),
        (np.array([0, y0, 0]), np.array([0, 1.0, 0])),
        (np.array([0, y1, 0]), np.array([0, -1.0, 0])),
        (np.array([0, 0, z0]), np.array([0, 0, 1.0])),
        (np.array([0, 0, z1]), np.array([0, 0, -1.0])),
    ]
    ts = []
    for p, n in planes:
        denom = d_w @ n
        num = float((p - C) @ n)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = num / denom
        ts.append(np.where(np.abs(denom) > 1e-9, t, np.inf))
    stack = np.stack(ts, axis=-1)
    stack = np.where(stack > 1e-6, stack, np.inf)
    idx = np.argmin(stack, axis=-1)
    t = np.take_along_axis(stack, idx[..., None], axis=-1)[..., 0]

    hit = np.isfinite(t)
    t = np.where(hit, t, 6.0)
    P = C + d_w * t[..., None]

    # --- 程序化纹理：低频明暗 + 棋盘格 + 高频噪声 ---
    low = 0.5 + 0.5 * np.sin(2.1 * P[..., 0]) * np.cos(1.7 * P[..., 2])
    chk = ((np.floor(P[..., 0] / 0.45) + np.floor(P[..., 2] / 0.45)) % 2).astype(np.float64)
    hsh = np.sin(P[..., 0] * 37.1 + P[..., 1] * 17.3 + P[..., 2] * 23.7) * 43758.5453
    hsh = hsh - np.floor(hsh)

    base = np.array([
        [0.82, 0.80, 0.76],   # -x 墙，暖白
        [0.74, 0.78, 0.82],   # +x 墙，冷白
        [0.86, 0.72, 0.66],   # -y 墙，浅砖
        [0.70, 0.76, 0.74],   # +y 墙，灰绿
        [0.45, 0.42, 0.40],   # 地面，深灰
        [0.92, 0.92, 0.90],   # 天花板，近白
    ])
    col = base[idx] * (0.55 + 0.45 * low[..., None])
    col = col * (1.0 - 0.18 * chk[..., None])
    col = col + 0.10 * (hsh[..., None] - 0.5)
    rgb = np.clip(col * 255.0, 0, 255).astype(np.uint8)

    depth_mm = np.clip(t * 1000.0, 0, 65535).astype(np.uint16)
    return rgb, depth_mm


def trajectory(n: int, room: dict) -> list[np.ndarray]:
    """一圈椭圆绕行 + 缓慢升降，倾角带一点俯视，模拟人手持着走一圈。"""
    x0, x1 = room["x"]
    y0, y1 = room["y"]
    cxr, cyr = (x0 + x1) / 2, (y0 + y1) / 2
    ax, ay = (x1 - x0) * 0.28, (y1 - y0) * 0.28
    poses = []
    for i in range(n):
        a = 2 * np.pi * i / n
        eye = np.array([
            cxr + ax * np.cos(a),
            cyr + ay * np.sin(a),
            1.15 + 0.25 * np.sin(2 * a),
        ])
        tang = np.array([-ax * np.sin(a), ay * np.cos(a), 0.0])
        inward = np.array([cxr - eye[0], cyr - eye[1], 0.0])
        # 主朝切线前方、只留一点内偏。内偏权重过大时（试过 0.35）朝向会在
        # 一个小扇区里来回摆，yaw 覆盖只有 ~140 度，导致部分墙面几乎无观测——
        # 这正是 coverage_report 要抓的采集缺陷，不该出现在基准数据里。
        fwd = 0.88 * tang / (np.linalg.norm(tang) + 1e-9) + 0.12 * inward / (
            np.linalg.norm(inward) + 1e-9
        )
        target = eye + np.array([fwd[0], fwd[1], -0.28])
        poses.append(look_at_cv(eye, target))
    return poses


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/sim", help="输出根目录")
    ap.add_argument("--name", default="room0")
    ap.add_argument("--frames", type=int, default=120)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--fps", type=float, default=10.0)
    args = ap.parse_args()

    room = {"x": (-4.0, 4.0), "y": (-3.0, 3.0), "z": (0.0, 3.0)}
    W, H = args.width, args.height
    fx = fy = 0.5 * W / np.tan(np.radians(45.0))
    K = (fx, fy, (W - 1) / 2.0, (H - 1) / 2.0)

    root = os.path.join(args.out, args.name)
    res = os.path.join(root, "results")
    os.makedirs(res, exist_ok=True)

    poses = trajectory(args.frames, room)
    for i, T in enumerate(poses):
        rgb, depth = render(T, room, K, W, H)
        d = os.path.join(res, f"frame{i:06d}")
        os.makedirs(d, exist_ok=True)
        Image.fromarray(rgb).save(os.path.join(d, "rgb.png"))
        Image.fromarray(depth).save(os.path.join(d, "depth.png"))
        if (i + 1) % 20 == 0:
            print(f"  {i + 1}/{args.frames} frames")

    with open(os.path.join(root, "traj.txt"), "w", encoding="utf-8") as f:
        for T in poses:
            f.write(" ".join(f"{v:.8f}" for v in T.reshape(-1)) + "\n")

    meta = {
        "source": "synthetic",
        "pose_convention": "opencv_c2w",
        "camera_model": "PINHOLE",
        "width": W,
        "height": H,
        "fx": fx, "fy": fy, "cx": K[2], "cy": K[3],
        "dist": [0.0, 0.0, 0.0, 0.0],
        "fps": args.fps,
        "room": room,
        "note": "depth 为 z-depth，单位 mm；纹理为程序化生成，无真实光照",
    }
    with open(os.path.join(root, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)

    print(f"written: {root}  ({args.frames} frames, {W}x{H})")
    print(f"  K = fx={fx:.2f} fy={fy:.2f} cx={K[2]:.2f} cy={K[3]:.2f}")


if __name__ == "__main__":
    main()
