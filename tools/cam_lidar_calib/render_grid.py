#!/usr/bin/env python3
"""把若干候选外参的投影渲染成一张联系表，用来肉眼判断哪个朝向是对的。

每个候选按 (yaw, pitch, roll, tx, ty, tz) 给出，解释为 R_lidar->camera + t_lidar->camera，
即 p_cam = R * p_lidar + t。
"""
import sys

import cv2
import numpy as np

DATA = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "/home/cj/tmp/dvlc/calib_data"
FX, FY, CX, CY = 903.8353, 905.4474, 654.1131, 363.7572
K1, K2, P1, P2, K3 = 0.131003, -0.416436, -0.000653, 0.004949, 0.380354
CELL = (640, 360)  # w, h


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
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], float)


def Ry(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], float)


def Rx(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], float)


BASE = np.array([[0, -1, 0], [0, 0, -1], [1, 0, 0]], float)

a = load_ply(DATA + "/calib_01.ply")
img = cv2.imread(DATA + "/calib_01.png", cv2.IMREAD_GRAYSCALE)
H, W = img.shape
key = np.floor(a[:, :3] / 0.04).astype(np.int64)
_, idx = np.unique(key, axis=0, return_index=True)
xyz = a[idx, :3].astype(np.float64)
print("点 %d" % len(xyz))


def render(yaw, pitch, roll, t):
    R = BASE @ Rz(np.deg2rad(yaw)) @ Ry(np.deg2rad(pitch)) @ Rx(np.deg2rad(roll))
    Pc = xyz @ R.T + np.asarray(t, float)
    Z = Pc[:, 2]
    m = Z > 0.2
    X, Y, Z = Pc[m, 0], Pc[m, 1], Pc[m, 2]
    xr, yr = X / Z, Y / Z
    r2 = xr * xr + yr * yr
    rad = 1 + K1 * r2 + K2 * r2 ** 2 + K3 * r2 ** 3
    xd = xr * rad + 2 * P1 * xr * yr + P2 * (r2 + 2 * xr * xr)
    yd = yr * rad + P1 * (r2 + 2 * yr * yr) + 2 * P2 * xr * yr
    u = FX * xd + CX
    v = FY * yd + CY
    ok = (u >= 0) & (u < W) & (v >= 0) & (v < H)
    u, v, Z = u[ok], v[ok], Z[ok]
    canvas = np.zeros((H, W), np.uint8)
    dn = np.clip((Z - np.percentile(Z, 2)) / max(1e-6, np.percentile(Z, 98) - np.percentile(Z, 2)), 0, 1)
    canvas[v.astype(int), u.astype(int)] = (255 * (1 - dn)).astype(np.uint8)
    canvas = cv2.dilate(canvas, np.ones((2, 2), np.uint8))
    out = np.clip(img.astype(np.float32) * 0.35 + canvas.astype(np.float32) * 1.15, 0, 255).astype(np.uint8)
    return cv2.cvtColor(cv2.resize(out, CELL, interpolation=cv2.INTER_AREA), cv2.COLOR_GRAY2BGR), len(u)


CANDS = [
    (-30, -20, 0, (0, 0, 0)),
    (-40, -10, 0, (0, 0, 0)),
    (-20, -10, 0, (0, 0, 0)),
    (-40, 0, 0, (0, 0, 0)),
    (-130, -14, -2, (0, 0, 0)),
    (0, 0, 0, (0, 0, 0)),
]
tiles = []
for i, (y, p, r, t) in enumerate(CANDS):
    tile, n = render(y, p, r, t)
    tiles.append(tile)
    cv2.putText(tile, "#%d yaw=%d pitch=%d roll=%d t=%s n=%d" % (i + 1, y, p, r, t, n),
                (6, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1, cv2.LINE_AA)

sheet = np.vstack([np.hstack(tiles[0:3]), np.hstack(tiles[3:6])])
out = sys.argv[2] if len(sys.argv) > 2 else "/home/cj/tmp/dvlc/sheet.png"
cv2.imwrite(out, sheet)
print("已写出", out, sheet.shape)
