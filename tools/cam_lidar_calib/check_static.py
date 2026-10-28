#!/usr/bin/env python3
"""判断采集期间设备是否静止：前后各累积若干帧点云，比较合并后的体素重叠率。

Mid360 是非重复扫描，单帧之间本就重叠不多（约 60%），
所以必须「各自累积一段时间再比」，才能区分“扫描模式不同”和“设备真的动了”。
"""
import sys

import numpy as np
import rosbag2_py
from rclpy.serialization import deserialize_message
from sensor_msgs.msg import PointCloud2

bag = sys.argv[1]
sec = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0

reader = rosbag2_py.SequentialReader()
reader.open(rosbag2_py.StorageOptions(uri=bag, storage_id="sqlite3"),
            rosbag2_py.ConverterOptions("", ""))
types = {t.name: t.type for t in reader.get_all_topics_and_types()}
pt = [k for k, v in types.items() if v.endswith("PointCloud2")][0]

times, clouds = [], []
while reader.has_next():
    topic, data, t = reader.read_next()
    if topic == pt:
        clouds.append(deserialize_message(data, PointCloud2))
        times.append(t / 1e9)

t0, t1 = times[0], times[-1]
print("时长 %.1fs，%d 帧，约 %.1f Hz" % (t1 - t0, len(clouds), len(clouds) / max(1e-6, t1 - t0)))


def to_xyz(c):
    n = c.width * c.height
    arr = np.frombuffer(bytes(c.data), dtype=np.uint8).reshape(n, c.point_step)
    off = {f.name: f.offset for f in c.fields}
    return np.stack([
        arr[:, off["x"]:off["x"] + 4].copy().view(np.float32).ravel(),
        arr[:, off["y"]:off["y"] + 4].copy().view(np.float32).ravel(),
        arr[:, off["z"]:off["z"] + 4].copy().view(np.float32).ravel(),
    ], axis=1)


def vox(Ps, r=0.08):
    out = set()
    for P in Ps:
        P = P[np.isfinite(P).all(axis=1) & (np.abs(P) < 100).all(axis=1)]
        out |= set(map(tuple, np.floor(P / r).astype(np.int64)))
    return out


head = [to_xyz(c) for c, t in zip(clouds, times) if t < t0 + sec]
tail = [to_xyz(c) for c, t in zip(clouds, times) if t > t1 - sec]
A, B = vox(head), vox(tail)
inter = len(A & B)
print("前 %.1fs 累积体素 %d，后 %.1fs 累积体素 %d" % (sec, len(A), sec, len(B)))
print("合并后重叠率 %.1f%%   (A 被 B 覆盖 %.1f%%)"
      % (100.0 * inter / max(1, len(A | B)), 100.0 * inter / max(1, len(A))))
print("判定：%s" % ("静止，可以用于标定" if 100.0 * inter / max(1, len(A)) > 85 else
                 "有位移，建议重新录制"))
