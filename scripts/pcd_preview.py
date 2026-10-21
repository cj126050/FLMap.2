#!/usr/bin/env python3
"""
pcd_preview.py —— 把一个 PCD 渲染成 PNG 预览图（不需要 RViz / GPU）

用途：
  · 在没装 RViz 的机器上，或者 ssh 里，快速确认 PCD 是不是一张"像样的图"
  · 出报告/发群里：一张俯视图比 287 MB 的 pcd 直观
  · 验证导出没坏：密度图上有墙、有点云结构，就说明数据是通的

不支持 RViz 那种交互，只是静态快照；要转视角就用 --view xy / xz / yz。

用法:
  python3 scripts/pcd_preview.py map.pcd                  # 生成 map_xy.png / map_xz.png
  python3 scripts/pcd_preview.py map.pcd --view xz        # 只看侧视
  python3 scripts/pcd_preview.py map.pcd --res 0.05       # 5cm 网格（默认 10cm）
  python3 scripts/pcd_preview.py map.pcd --info           # 只打统计，不画图
"""

import argparse
import os
import sys

import numpy as np


def read_pcd(path):
    """读 PCD，返回 (xyz float32 [N,3], intensity 或 None)。

    只处理 bag_to_pcd.py 产出的格式（binary / FIELDS x y z intensity）。
    遇到 ascii 或其它字段组合也能尽量兜住，兜不住就报清楚原因。
    """
    with open(path, "rb") as f:
        header = {}
        while True:
            line = f.readline()
            if not line:
                raise ValueError("PCD 头没读完就 EOF —— 文件被截断了？")
            txt = line.decode("ascii", "replace").strip()
            if not txt or txt.startswith("#"):
                continue
            key, _, val = txt.partition(" ")
            header[key.upper()] = val.strip()
            if key.upper() == "DATA":
                break
        fields = header.get("FIELDS", "x y z").split()
        size = [int(x) for x in header.get("SIZE", "4 4 4").split()]
        types = header.get("TYPE", "F F F").split()
        counts = [int(x) for x in header.get("COUNT", " ".join(["1"] * len(fields))).split()]
        npts = int(header.get("POINTS", "0"))
        data = header.get("DATA", "binary").lower()

        if data != "binary":
            raise ValueError(f"只支持 DATA binary，这个文件是 {data}；用 pcl_convert 转过再来")
        if any(t != "F" for t in types) or any(s != 4 for s in size) or any(c != 1 for c in counts):
            raise ValueError(f"只支持 float32 单值字段，实际 SIZE={size} TYPE={types} COUNT={counts}")

        raw = np.fromfile(f, dtype=np.float32)
        if npts <= 0:
            npts = raw.size // len(fields)
        raw = raw[: npts * len(fields)].reshape(npts, len(fields))
        idx = [fields.index(k) for k in ("x", "y", "z")]
        xyz = np.ascontiguousarray(raw[:, idx], dtype=np.float32)
        inten = raw[:, fields.index("intensity")] if "intensity" in fields else None
    return xyz, inten


def render(xyz, out, view, res):
    """把点云画成密度图。密度图比散点快得多（1800 万点散点要几分钟）。"""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ax_i, ay_i = {"xy": (0, 1), "xz": (0, 2), "yz": (1, 2)}[view]
    a, b = xyz[:, ax_i], xyz[:, ay_i]
    # 去掉离群点（FAST-LIO 偶尔会甩出几百米的飞点，会把整张图压成一坨）
    m = (np.abs(a) < 200) & (np.abs(b) < 200)
    a, b = a[m], b[m]
    if a.size == 0:
        print("点云全被离群过滤掉了，图会是空的", file=sys.stderr)
        return False

    H, xe, ye = np.histogram2d(a, b, bins=[
        np.arange(a.min(), a.max() + res, res),
        np.arange(b.min(), b.max() + res, res),
    ])
    H = np.log1p(H).T  # 对数尺度，否则稀疏处全黑

    dpi = 110
    fig_w = max(6.0, min(16.0, (a.max() - a.min()) / 8))
    fig_h = max(4.0, fig_w * (b.max() - b.min()) / max(1e-6, (a.max() - a.min())))
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=dpi)
    ax.imshow(H, origin="lower", cmap="viridis", extent=[xe[0], xe[-1], ye[0], ye[-1]],
              interpolation="nearest", aspect="equal")
    ax.set_xlabel({"xy": "x [m]", "xz": "x [m]", "yz": "y [m]"}[view])
    ax.set_ylabel({"xy": "y [m]", "xz": "z [m]", "yz": "z [m]"}[view])
    ax.set_title(f"PCD preview ({view})  {a.size:,} pts  res {res*100:.0f} cm")
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcd")
    ap.add_argument("--view", choices=["xy", "xz", "yz"], action="append",
                    help="可重复；默认 xy + xz")
    ap.add_argument("--res", type=float, default=0.1, help="网格边长（米），默认 0.1")
    ap.add_argument("--out", help="输出前缀，默认与 pcd 同名")
    ap.add_argument("--info", action="store_true", help="只打统计")
    args = ap.parse_args()

    xyz, inten = read_pcd(args.pcd)
    n = xyz.shape[0]
    print(f"点云: {n:,} 点   文件: {args.pcd} ({os.path.getsize(args.pcd)/1e6:.1f} MB)")
    if n == 0:
        print("空点云 —— 雷达没出图，或者导出时话题没数据", file=sys.stderr)
        return 1
    lo, hi = xyz.min(axis=0), xyz.max(axis=0)
    print(f"范围 X[{lo[0]:.2f},{hi[0]:.2f}] Y[{lo[1]:.2f},{hi[1]:.2f}] Z[{lo[2]:.2f},{hi[2]:.2f}]  跨度 "
          f"{hi[0]-lo[0]:.1f} × {hi[1]-lo[1]:.1f} × {hi[2]-lo[2]:.1f} m")
    if inten is not None:
        print(f"强度 {inten.min():.0f} … {inten.max():.0f}")
    if args.info:
        return 0

    prefix = args.out or os.path.splitext(args.pcd)[0]
    views = args.view or ["xy", "xz"]
    ok = 0
    for v in views:
        out = f"{prefix}_{v}.png"
        if render(xyz, out, v, args.res):
            print(f"已生成 {out}")
            ok += 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
