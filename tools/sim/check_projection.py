"""投影自检：把点云投到同帧图像上，量化"位姿链是否自洽"（M1 与 B6 的验收工具）。

这是整条链路里性价比最高的一个检查。坐标系翻错、内外参错位、时间偏移，
都会在这一个数字上暴露：

  · 深度误差（中位 / p90，米）—— 点云 z 与该像素的 GT 深度之差
  · 图内落点比例 —— 位姿或内参错得离谱时，点会大面积飞出画面

两种用法：
  有 GT depth（合成数据 / Replica）→ 算**绝对**误差，正确实现应在毫米级
  真实 bag                          → 无 GT depth，只看覆盖率 + 叠图目检

注意它验证什么、不验证什么：深度误差接近 0 只能说明「投影公式 + 位姿链 +
内参」三者自洽；它不能证明标定本身准确（点云和深度同源时，外参错了也自洽）。
真实场景的最终判据永远是叠图上墙角是否与像素边缘重合。

用法：
    /usr/bin/python3 tools/sim/check_projection.py \
        --dataset data/sim/ds --kf data/sim/kf --scene data/sim/room0 \
        --frames 3 --out proj_check.png
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.sim.kf_core import FLIP_YZ  # noqa: E402


def read_ply_xyz(path: str) -> np.ndarray:
    with open(path, "rb") as f:
        raw = f.read()
    marker = b"end_header\n"
    head_end = raw.index(marker) + len(marker)
    head = raw[:head_end].decode("ascii", errors="ignore")
    n = int([ln for ln in head.splitlines() if ln.startswith("element vertex")][0].split()[-1])
    props = [ln.split()[-1] for ln in head.splitlines() if ln.startswith("property float")]
    dt = np.dtype([(p, "<f4") for p in props])
    rec = np.frombuffer(raw[head_end:], dtype=dt, count=n)
    return np.stack([rec["x"], rec["y"], rec["z"]], axis=1).astype(np.float32)


def read_pcd_xyz(path: str) -> np.ndarray:
    with open(path, "rb") as f:
        raw = f.read()
    marker = b"DATA binary\n"
    if marker not in raw:
        return np.zeros((0, 3), dtype=np.float32)
    head_end = raw.index(marker) + len(marker)
    head = raw[:head_end].decode("ascii", errors="ignore")
    fields, sizes, types = [], [], []
    for ln in head.splitlines():
        k, _, v = ln.partition(" ")
        if k == "FIELDS":
            fields = v.split()
        elif k == "SIZE":
            sizes = [int(x) for x in v.split()]
        elif k == "TYPE":
            types = v.split()
    tmap = {"F": "f", "U": "u", "I": "i"}
    dt = np.dtype([(f_, f"{tmap[t]}{s}") for f_, s, t in zip(fields, sizes, types)])
    arr = np.frombuffer(raw[head_end:], dtype=dt)
    return np.stack([arr["x"], arr["y"], arr["z"]], axis=1).astype(np.float32)


def project(P_w, T_c2w_cv, K, W, H):
    R, t = T_c2w_cv[:3, :3], T_c2w_cv[:3, 3]
    P_c = (P_w - t) @ R
    z = P_c[:, 2]
    ok = z > 0.05
    u = np.full(len(P_w), -1.0)
    v = np.full(len(P_w), -1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        u[ok] = K[0, 0] * P_c[ok, 0] / z[ok] + K[0, 2]
        v[ok] = K[1, 1] * P_c[ok, 1] / z[ok] + K[1, 2]
    inside = ok & (u >= 0) & (u < W) & (v >= 0) & (v < H)
    return u, v, z, inside


def overlay(img, u, v, inside, z, color=(255, 40, 190), step=1):
    """把点画成 3x3 的小块，而不是单像素。

    单像素点在缩略图里会直接消失，让人误以为"只有地面有点、墙没投上"，
    从而怀疑坐标系 —— 实际上墙面点一直都在，只是看不见。3x3 + 洋红色
    在灰白场景上对比最强，也经得起缩放。
    """
    out = img.astype(np.float32).copy()
    H, W = out.shape[:2]
    ui = u[inside][::step].astype(np.int32)
    vi = v[inside][::step].astype(np.int32)
    zz = z[inside][::step]
    if len(ui) == 0:
        return out.astype(np.uint8)
    alpha = np.clip(1.25 - 0.12 * zz, 0.35, 0.95)[:, None]
    c = np.array(color, dtype=np.float32)[None, :]
    for dy in (0, 1):
        for dx in (0, 1):
            yy = np.clip(vi + dy, 0, H - 1)
            xx = np.clip(ui + dx, 0, W - 1)
            out[yy, xx] = (1.0 - alpha) * out[yy, xx] + alpha * c
    return np.clip(out, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True, help="build_dataset.py 的产物目录")
    ap.add_argument("--kf", default="", help="kf 目录；给了就用每帧自己的点云")
    ap.add_argument("--scene", default="", help="源场景目录（含 results/frame*/depth.png）")
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--out", default="")
    ap.add_argument("--tol", type=float, default=0.05, help="深度误差阈值（米）")
    args = ap.parse_args()

    with open(os.path.join(args.dataset, "transforms.json"), "r", encoding="utf-8") as f:
        tjs = json.load(f)
    W, H = tjs["w"], tjs["h"]
    K = np.array([[tjs["fl_x"], 0, tjs["cx"]],
                  [0, tjs["fl_y"], tjs["cy"]],
                  [0, 0, 1.0]])

    src_of = {}
    if args.kf:
        with open(os.path.join(args.kf, "index.json"), "r", encoding="utf-8") as f:
            idx = json.load(f)
        src_of = {f"{fr['id']:06d}": fr["src_index"] for fr in idx["frames"]}

    ply = os.path.join(args.dataset, "init.ply")
    P_global = read_ply_xyz(ply) if os.path.exists(ply) else np.zeros((0, 3), np.float32)
    have_depth = bool(args.scene) and bool(args.kf)
    print(f"[PROJ] {len(tjs['frames'])} 帧, {W}x{H}, init.ply {len(P_global)} 点, "
          f"GT depth {'可用' if have_depth else '不可用（只看覆盖率）'}")

    rows, tiles, seq = [], [], []
    for i in range(min(args.frames, len(tjs["frames"]))):
        fr = tjs["frames"][i]
        T_cv = np.array(fr["transform_matrix"], dtype=np.float64) @ FLIP_YZ

        img = np.array(Image.open(os.path.join(args.dataset, fr["file_path"])).convert("RGB"))

        fid = os.path.basename(fr["file_path"]).split(".")[0]
        P, tag = P_global, "init.ply"
        pcd = os.path.join(args.kf, fid, "cloud.pcd") if args.kf else ""
        if pcd and os.path.exists(pcd):
            P = read_pcd_xyz(pcd)
            tag = f"kf/{fid}"

        u, v, z, inside = project(P, T_cv, K, W, H)

        err_med = err_p90 = float("nan")
        depth_png = ""
        if have_depth and fid in src_of:
            depth_png = os.path.join(args.scene, "results",
                                     f"frame{src_of[fid]:06d}", "depth.png")
        d_img = None
        if depth_png and os.path.exists(depth_png) and inside.any():
            d_img = np.asarray(Image.open(depth_png), dtype=np.float32) / 1000.0
            ui = np.clip(u[inside].astype(np.int32), 0, W - 1)
            vi = np.clip(v[inside].astype(np.int32), 0, H - 1)
            d_at = d_img[vi, ui]
            valid = d_at > 0.1
            if valid.sum() > 100:
                err = np.abs(z[inside][valid] - d_at[valid])
                err_med = float(np.median(err))
                err_p90 = float(np.percentile(err, 90))

        rows.append({
            "frame": i + 1, "points": len(P), "src": tag,
            "ratio": float(inside.mean()) if len(P) else 0.0,
            "z_med": float(np.median(z[inside])) if inside.any() else 0.0,
            "err_med": err_med, "err_p90": err_p90,
        })
        seq.append({"T": T_cv, "P": P, "d": d_img, "img": img})
        tiles.append(overlay(img, u, v, inside, z, step=max(1, len(P) // 5000)))

    print(f"{'帧':>3} {'点数':>7} {'图内':>7} {'中位深度':>9} {'深度误差中位':>11} {'p90':>7}")
    for r in rows:
        em = "   —  " if np.isnan(r["err_med"]) else f"{r['err_med']*1000:6.1f}mm"
        ep = "   —  " if np.isnan(r["err_p90"]) else f"{r['err_p90']*1000:5.1f}mm"
        print(f"{r['frame']:>3} {r['points']:>7} {r['ratio']*100:>6.1f}% "
              f"{r['z_med']:>8.2f}m {em:>11} {ep:>7}")

    print()
    ratios_ok = all(r["ratio"] > 0.15 for r in rows)
    print(f"[PROJ] 图内落点均 > 15% : {'是' if ratios_ok else '否 —— 坐标系或内参大概率错了'}")

    errs = [r["err_med"] for r in rows if not np.isnan(r["err_med"])]
    if errs:
        worst = max(errs)
        print(f"[PROJ] 深度误差中位最差 {worst*1000:.1f} mm，阈值 {args.tol*1000:.0f} mm : "
              f"{'通过' if worst <= args.tol else '不通过 —— 查位姿链与内参'}")
        print("[PROJ] 说明：点云与 depth 同源时误差必然很小，此项只证明公式自洽，"
              "不证明标定准确")

    # ---- 跨帧投影：把 A 帧的点云投到 B 帧，用 B 的 GT depth 判定 ----
    # 同帧投影是循环论证（点由 depth 生成，投回去必然重合）。跨帧才有意义。
    # 但深度判据只对**沿视线方向**的平移敏感：横向平移不改变深度，只会让点在
    # 像素上横移。所以下面同时给 photometric 误差 —— 同一 3D 点在两帧里的颜色
    # 差异，横向错位会让它落到不同的纹理上，从而暴露出来。
    cross = []
    pairs = [(a, b) for a, b in zip(seq, seq[1:]) if a["d"] is not None and b["d"] is not None]
    for k, (a, b) in enumerate(pairs, start=1):
        u, v, z, inside = project(a["P"], b["T"], K, W, H)
        if not inside.any():
            continue
        ui = np.clip(u[inside].astype(np.int32), 0, W - 1)
        vi = np.clip(v[inside].astype(np.int32), 0, H - 1)
        d_at = b["d"][vi, ui]
        valid = d_at > 0.1
        if valid.sum() < 200:
            continue
        err = np.abs(z[inside][valid] - d_at[valid])

        # photometric：A 点在自己帧里的颜色 vs 在 B 帧投影处的颜色
        ua, va, _, insa = project(a["P"], a["T"], K, W, H)
        ub, vb, _, insb = project(a["P"], b["T"], K, W, H)
        common = insa & insb
        perr = float("nan")
        if common.sum() > 200:
            ca = a["img"][np.clip(va[common].astype(np.int32), 0, H - 1),
                          np.clip(ua[common].astype(np.int32), 0, W - 1)].astype(np.float32)
            cb = b["img"][np.clip(vb[common].astype(np.int32), 0, H - 1),
                          np.clip(ub[common].astype(np.int32), 0, W - 1)].astype(np.float32)
            perr = float(np.median(np.abs(ca - cb).mean(axis=1)))

        cross.append({
            "pair": f"{k}->{k+1}",
            "overlap": float(inside.mean()),
            "inlier": float((err < args.tol).mean()),
            "med": float(np.median(err)),
            "photo": perr,
        })

    if cross:
        print("\n[PROJ] 跨帧投影（A 帧点云投到 B 帧）")
        print(f"{'帧对':>8} {'重叠率':>8} {'深度inlier':>10} {'中位误差':>9} {'颜色差':>7}")
        for c in cross:
            ph = "  —  " if np.isnan(c["photo"]) else f"{c['photo']:5.1f}"
            print(f"{c['pair']:>8} {c['overlap']*100:>7.1f}% {c['inlier']*100:>9.1f}% "
                  f"{c['med']*1000:>7.1f}mm {ph:>7}")
        avg = float(np.mean([c["inlier"] for c in cross]))
        print(f"[PROJ] 平均深度 inlier {avg*100:.1f}% : "
              f"{'通过（位姿链可信）' if avg > 0.6 else '不通过 —— 位姿或时间戳有问题'}")
        phs = [c["photo"] for c in cross if not np.isnan(c["photo"])]
        if phs:
            print(f"[PROJ] 平均颜色差 {np.mean(phs):.1f}/255 —— 明显偏大说明横向错位"
                  "（深度判据抓不到这一类）")
        print("[PROJ] 注：真实场景遮挡多、有光照变化，绝对数值不可与合成数据对比，看趋势")

    if args.out and tiles:
        h = min(t.shape[0] for t in tiles)
        Image.fromarray(np.concatenate([t[:h] for t in tiles], axis=1)).save(args.out)
        print(f"\n[PROJ] 叠图: {args.out}（看墙角、门框是否与像素边缘重合）")


if __name__ == "__main__":
    main()
