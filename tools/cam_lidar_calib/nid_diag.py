#!/usr/bin/env python3
"""诊断 NID 目标函数：给定朝向的 NID 值 + 带点数约束的搜索。

Mid360 单帧 ~2 万点铺满 360°，落进 70° 相机锥内只有几千点；NID 在低重叠时会
系统性偏低（伪相关），所以搜索必须限制最小 in-view 点数。
"""
import sys

import cv2
import numpy as np

BINS = 16
FX, FY, CX, CY = 903.8353, 905.4474, 654.1131, 363.7572
K1, K2, P1, P2, K3 = 0.131003, -0.416436, -0.000653, 0.004949, 0.380354
DATA = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "/home/cj/tmp/dvlc/calib_data"


def load_ply(path):
    with open(path, "rb") as f:
        n = None
        while True:
            s = f.readline().decode("ascii", "ignore").strip()
            if s.startswith("element vertex"):
                n = int(s.split()[-1])
            if s == "end_header":
                break
        return np.frombuffer(f.read(n * 16), dtype=np.float32).reshape(n, 4)


def Rz(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], np.float64)


def Ry(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], np.float64)


def Rx(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], np.float64)


BASE = np.array([[0, -1, 0], [0, 0, -1], [1, 0, 0]], np.float64)

a = load_ply(DATA + "/calib_01.ply")
img = cv2.imread(DATA + "/calib_01.png", cv2.IMREAD_GRAYSCALE)
H, W = img.shape
imgn = img.astype(np.float64) / 255.0
key = np.floor(a[:, :3] / 0.03).astype(np.int64)
_, idx = np.unique(key, axis=0, return_index=True)
xyz = a[idx, :3].astype(np.float64)
pb = np.clip((a[idx, 3].astype(np.float64) * BINS).astype(np.int32), 0, BINS - 1)
print("下采样点数 %d，图 %dx%d" % (len(xyz), W, H))


def nid(R, t=(0.0, 0.0, 0.0), verbose=False):
    Pc = xyz @ R.T + np.asarray(t)
    Z = Pc[:, 2]
    m = Z > 0.15
    X, Y, Z = Pc[m, 0], Pc[m, 1], Pc[m, 2]
    pbv = pb[m]
    xr, yr = X / Z, Y / Z
    r2 = xr * xr + yr * yr
    rad = 1 + K1 * r2 + K2 * r2 ** 2 + K3 * r2 ** 3
    xd = xr * rad + 2 * P1 * xr * yr + P2 * (r2 + 2 * xr * xr)
    yd = yr * rad + P1 * (r2 + 2 * yr * yr) + 2 * P2 * xr * yr
    u = FX * xd + CX
    v = FY * yd + CY
    ok = (u >= 1) & (u < W - 2) & (v >= 1) & (v < H - 2)
    if ok.sum() < 200:
        return 2.0, 0
    u, v, pbv = u[ok], v[ok], pbv[ok]
    ui, vi = u.astype(np.int32), v.astype(np.int32)
    fu, fv = u - ui, v - vi
    pix = (imgn[vi, ui] * (1 - fu) * (1 - fv) + imgn[vi, ui + 1] * fu * (1 - fv)
           + imgn[vi + 1, ui] * (1 - fu) * fv + imgn[vi + 1, ui + 1] * fu * fv)
    ib = np.clip((pix * BINS).astype(np.int32), 0, BINS - 1)
    joint = np.histogram2d(ib, pbv, bins=[BINS, BINS], range=[[0, BINS], [0, BINS]])[0].astype(np.float64)
    joint /= joint.sum()
    hi, hp = joint.sum(axis=1), joint.sum(axis=0)
    eps = 1e-6
    Hj = -(joint * np.log(joint + eps)).sum()
    Hi = -(hi * np.log(hi + eps)).sum()
    Hp = -(hp * np.log(hp + eps)).sum()
    MI = Hi + Hp - Hj
    if verbose:
        print("    H_joint=%.4f H_img=%.4f H_pts=%.4f MI=%.4f" % (Hj, Hi, Hp, MI))
    return (Hj - MI) / Hj, int(ok.sum())


Yi, Pi, Ri = -130, -14, -2
R0 = BASE @ Rz(np.deg2rad(Yi)) @ Ry(np.deg2rad(Pi)) @ Rx(np.deg2rad(Ri))
n0, c0 = nid(R0, verbose=True)
print("初值 yaw=%d pitch=%d roll=%d -> NID=%.4f (点数 %d)  [对应 Ceres f=%.4f]"
      % (Yi, Pi, Ri, n0, c0, n0 ** 2))

print("\n=== 固定 pitch=-14 roll=-2，只扫 yaw ===")
for yaw in range(-180, 180, 10):
    R = BASE @ Rz(np.deg2rad(yaw)) @ Ry(np.deg2rad(Pi)) @ Rx(np.deg2rad(Ri))
    n, c = nid(R)
    print("  yaw=%4d  NID=%.4f  n=%5d %s" % (yaw, n, c, "<== 初值" if yaw == Yi else ""))

print("\n=== 全网格（要求 in-view 点数 >= 3000）===")
rows = []
for yaw in range(-180, 180, 5):
    for pitch in range(-40, 41, 5):
        for roll in range(-30, 31, 5):
            R = BASE @ Rz(np.deg2rad(yaw)) @ Ry(np.deg2rad(pitch)) @ Rx(np.deg2rad(roll))
            n, c = nid(R)
            if c >= 3000:
                rows.append((n, yaw, pitch, roll, c))
rows.sort()
print("  合格候选 %d 个" % len(rows))
print("     NID    yaw pitch roll    点数")
for n, yaw, p, r, c in rows[:12]:
    print("  %7.4f  %4d %5d %4d  %6d" % (n, yaw, p, r, c))
