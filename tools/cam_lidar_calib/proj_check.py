#!/usr/bin/env python3
"""把点云按外参投到相机图像上，生成叠加图，用来肉眼判断外参准不准。

用法:
  proj_check.py <bag_dir> <out.png> [x y z qx qy qz qw]
参数是 DVLCalib 的 T_lidar_camera（camera->lidar，p_lidar = T * p_camera）：
  p_cam = R^T * (p_lidar - t),  R = R_lidar_camera
不给外参时用「相机与雷达同向安装」的默认猜测（雷达 x前/y左/z上 -> 相机 x右/y下/z前）。

点云按深度着色（近暖远冷），叠加在原图 55% 上；左图为叠加，右图为原图便于对比。
"""
import sys

import cv2
import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from sensor_msgs.msg import Image, PointCloud2

FX, FY, CX, CY = 903.8353, 905.4474, 654.1131, 363.7572
K1, K2, P1, P2, K3 = 0.131003, -0.416436, -0.000653, 0.004949, 0.380354

bag_dir = sys.argv[1]
out_png = sys.argv[2]
T = [float(v) for v in sys.argv[3:10]] if len(sys.argv) >= 10 else None

# 默认猜测：q 由 R = [[0,0,1],[-1,0,0],[0,-1,0]] 得到（p_lidar = R * p_cam）
if T is None:
    R = np.array([[0, 0, 1], [-1, 0, 0], [0, -1, 0]], dtype=float)
    # 矩阵转四元数
    m = R
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    qw = np.sqrt(max(0.0, 1 + tr)) / 2
    qx = (m[2, 1] - m[1, 2]) / (4 * qw)
    qy = (m[0, 2] - m[2, 0]) / (4 * qw)
    qz = (m[1, 0] - m[0, 1]) / (4 * qw)
    T = [0.0, 0.0, 0.0, qx, qy, qz, qw]
    print("使用默认猜测 T_lidar_camera =", np.round(T, 4))

reader = rosbag2_py.SequentialReader()
reader.open(rosbag2_py.StorageOptions(uri=bag_dir, storage_id="sqlite3"),
            rosbag2_py.ConverterOptions("", ""))
types = {t.name: t.type for t in reader.get_all_topics_and_types()}
img_topic = [k for k, v in types.items() if v.endswith("msg/Image")][0]
pc_topic = [k for k, v in types.items() if v.endswith("PointCloud2")][0]

img = None
pts_all = []
while reader.has_next():
    topic, data, _ = reader.read_next()
    if topic == img_topic and img is None:
        m = deserialize_message(data, Image)
        a = np.frombuffer(bytes(m.data), dtype=np.uint8).reshape(m.height, m.width, -1)
        img = a[:, :, :3].copy() if m.encoding == "rgb8" else a[:, :, 2::-1].copy()
    elif topic == pc_topic:
        c = deserialize_message(data, PointCloud2)
        n = c.width * c.height
        arr = np.frombuffer(bytes(c.data), dtype=np.uint8).reshape(n, c.point_step)
        off = {f.name: f.offset for f in c.fields}
        pts_all.append(np.stack([
            arr[:, off["x"]:off["x"] + 4].copy().view(np.float32).ravel(),
            arr[:, off["y"]:off["y"] + 4].copy().view(np.float32).ravel(),
            arr[:, off["z"]:off["z"] + 4].copy().view(np.float32).ravel(),
        ], axis=1))

P = np.concatenate(pts_all)
P = P[np.isfinite(P).all(axis=1) & (np.linalg.norm(P, axis=1) > 0.4)]
# 体素下采样，避免点太密看不清
v = np.floor(P / 0.05).astype(np.int64)
_, idx = np.unique(v, axis=0, return_index=True)
P = P[idx]
print("点云 %d 点，图像 %s" % (len(P), img.shape))

q = np.array(T[3:7])
nq = np.linalg.norm(q)
q = q / nq
x, y, z, w = q
R = np.array([
    [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
    [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
    [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
])
t = np.array(T[:3])
# T 是 T_lidar_camera(camera->lidar)，取逆得到 lidar->camera
Rlc = R.T                    # R_camera_lidar = R_lidar_camera^T
tlc = -R.T @ t               # t_camera_lidar = -R^T * t_lidar_camera
Pc = (Rlc @ P.T).T + tlc
front = Pc[:, 2] > 0.1
Pc = Pc[front]
print("落在相机前方的点: %d (%.0f%%)" % (len(Pc), 100.0 * len(Pc) / max(1, len(P))))

X, Y, Z = Pc[:, 0], Pc[:, 1], Pc[:, 2]
xr, yr = X / Z, Y / Z
r2 = xr * xr + yr * yr
rad = 1 + K1 * r2 + K2 * r2 ** 2 + K3 * r2 ** 3
xd = xr * rad + 2 * P1 * xr * yr + P2 * (r2 + 2 * xr * xr)
yd = yr * rad + P1 * (r2 + 2 * yr * yr) + 2 * P2 * xr * yr
u = FX * xd + CX
vv = FY * yd + CY

h, w = img.shape[:2]
inside = (u >= 0) & (u < w) & (vv >= 0) & (vv < h)
print("投到画面内: %d (%.0f%% of 前方点)" % (inside.sum(), 100.0 * inside.sum() / max(1, len(u))))

depth = Z[inside]
u, vv = u[inside], vv[inside]
dlo, dhi = np.percentile(depth, 2), np.percentile(depth, 98)
dn = np.clip((depth - dlo) / max(1e-6, dhi - dlo), 0, 1)
col = cv2.applyColorMap((255 * (1 - dn)).astype(np.uint8).reshape(-1, 1), cv2.COLORMAP_JET)
col = col.reshape(-1, 3)

canvas = np.zeros_like(img)
canvas[(vv.astype(int), u.astype(int))] = col
# 让点更可见
canvas = cv2.dilate(canvas, np.ones((2, 2), np.uint8))

overlay = cv2.addWeighted(img, 0.55, canvas, 0.85, 0)
both = np.hstack([overlay, img])
# 等比缩小便于查看
scale = min(1.0, 1600.0 / both.shape[1])
if scale < 1.0:
    both = cv2.resize(both, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
cv2.imwrite(out_png, cv2.cvtColor(both, cv2.COLOR_RGB2BGR))
print("已写出", out_png, both.shape)
