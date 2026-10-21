#!/usr/bin/env python3
"""从 rosbag2 录像里把 /cloud_registered 转成二进制 PCD。

为什么这个脚本写得这么"绕"
--------------------------
狗端（Foxy）上坑很多，每一条都能让导出失败，而且失败得毫无提示：

1. `sensor_msgs_py` 是 Galactic 才从 sensor_msgs 拆出来的模块，Foxy 没有，
   import 就 ModuleNotFoundError —— 但它跟"点云有没有数据"毫无关系。
2. 狗端镜像里 **没装 rosbag2_py**（`ros2 bag` 命令行在，Python 绑定缺），
   `import rosbag2_py` 同样直接崩。
3. 就算能读，Foxy 的 `read_points` 返回 tuple 列表，Humble 返回结构化 ndarray，
   两代写法不兼容。

所以这里：
  - 读包有两条路：有 rosbag2_py 就用它（PC 上正常），没有就直接用 sqlite3
    读 .db3 的 messages 表（狗端走这条）。rclpy + sensor_msgs 是 ROS 基础包，
    一定在。
  - 点云不用任何 read_points，按 PointField 的 offset/datatype 自己拆列，
    这样 point_step=48（FAST-LIO2 的 /cloud_registered）也不会串位。

用法:
    python3 scripts/bag_to_pcd.py <bag目录或任务目录> <输出.pcd>

    目录可以给 scan/ 本身，也可以给它的父目录（会自动向下找 metadata.yaml）。
    强制走 sqlite3 分支（排查用）: FLMAP_PCD_FORCE_SQLITE=1 python3 ...

退出码: 0 成功; 2 bag 打不开 / 没有该话题; 3 有话题但一帧可用数据都没有
"""

import os
import sqlite3
import sys

import numpy as np

TOPIC = "/cloud_registered"

PF_DTYPE = {
    1: "i1", 2: "u1", 3: "i2", 4: "u2",
    5: "i4", 6: "u4", 7: "f4", 8: "f8",
}


def find_bag(path):
    """接受 bag 目录本身或其父目录，返回真正含数据的目录。"""
    if os.path.isfile(os.path.join(path, "metadata.yaml")):
        return path
    for root, _dirs, files in os.walk(path):
        if "metadata.yaml" in files:
            return root
        for f in files:
            if f.endswith(".db3") or f.endswith(".mcap"):
                return root
    return path


def storage_id_of(bag_dir):
    """从 metadata.yaml 读真实存储后端，别硬编码（Humble 默认 mcap）。"""
    try:
        with open(os.path.join(bag_dir, "metadata.yaml"), "r",
                  encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if s.startswith("storage_identifier:"):
                    return s.split(":", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return "sqlite3"


def _open_rosbag2(bag_dir, storage):
    """返回 (types, 迭代器, 后端描述)。rosbag2_py 缺失时抛 ImportError。"""
    import rosbag2_py
    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=bag_dir, storage_id=storage),
        rosbag2_py.ConverterOptions("cdr", "cdr"),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}

    def gen():
        while reader.has_next():
            topic, data, _t = reader.read_next()
            yield topic, data

    return types, gen(), "rosbag2_py / " + storage


def _open_sqlite(bag_dir):
    """直接读 rosbag2 的 sqlite3 文件：topics(id,name,type) + messages(topic_id,data)。

    这是狗端实际走的路 —— 镜像里没有 rosbag2_py，但 sqlite3 是标准库。
    """
    db = None
    for f in sorted(os.listdir(bag_dir)):
        if f.endswith(".db3"):
            db = os.path.join(bag_dir, f)
            break
    if db is None:
        raise RuntimeError(f"{bag_dir} 下没有 .db3 文件")

    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    rows = list(con.execute("SELECT id, name, type FROM topics"))
    id2name = {i: n for i, n, _ in rows}
    types = {n: t for _, n, t in rows}

    def gen():
        cur = con.execute("SELECT topic_id, data FROM messages ORDER BY timestamp")
        for tid, data in cur:
            yield id2name.get(tid, "?"), bytes(data)

    return types, gen(), "sqlite3 直读 / " + os.path.basename(db)


def open_bag(bag_dir, storage):
    force = os.environ.get("FLMAP_PCD_FORCE_SQLITE") == "1"
    if not force:
        try:
            return _open_rosbag2(bag_dir, storage)
        except ImportError:
            if storage != "sqlite3":
                raise RuntimeError(
                    f"没有 rosbag2_py，而 bag 是 {storage} 格式，无法直读（只支持 sqlite3）")
    return _open_sqlite(bag_dir)


def columns_of(msg):
    """按 PointField 的 offset/type 构造一个刚好覆盖 point_step 的 numpy dtype。"""
    names, formats, offsets = [], [], []
    for f in msg.fields:
        key = {"intensity": "i"}.get(f.name, f.name)
        if key not in ("x", "y", "z", "i"):
            continue
        code = PF_DTYPE.get(f.datatype)
        if code is None:
            continue
        names.append(key)
        formats.append(np.dtype(code))
        offsets.append(f.offset)
    if not {"x", "y", "z"} <= set(names):
        return None
    return np.dtype({"names": names, "formats": formats,
                     "offsets": offsets, "itemsize": msg.point_step})


def frame_to_xyz(msg):
    """把一帧 PointCloud2 变成 (N,4) float32 的 x y z intensity，丢掉 NaN/Inf。"""
    n = msg.width * msg.height
    if n == 0 or msg.point_step == 0 or len(msg.data) < n * msg.point_step:
        return None
    dt = columns_of(msg)
    if dt is None:
        return None
    arr = np.frombuffer(bytes(msg.data), dtype=dt, count=n)

    xyz = np.empty((n, 3), dtype=np.float32)
    xyz[:, 0] = arr["x"]
    xyz[:, 1] = arr["y"]
    xyz[:, 2] = arr["z"]
    ok = np.isfinite(xyz).all(axis=1)
    it = arr["i"].astype(np.float32) if "i" in arr.dtype.names else np.zeros(n, np.float32)
    return np.column_stack((xyz[ok], it[ok]))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, out = sys.argv[1], sys.argv[2]

    bag_dir = find_bag(src)
    if not os.path.isdir(bag_dir):
        print(f"[ERROR] {src} 不存在", file=sys.stderr)
        return 2

    storage = storage_id_of(bag_dir)
    try:
        types, stream, backend = open_bag(bag_dir, storage)
    except Exception as e:                                   # noqa: BLE001
        print(f"[ERROR] 打不开 bag: {type(e).__name__}: {e}", file=sys.stderr)
        return 2

    print(f"[info] bag={bag_dir}")
    print(f"[info] backend={backend}")

    if TOPIC not in types:
        print(f"[ERROR] 里面没有 {TOPIC}，只有: {sorted(types) or '（空 bag）'}",
              file=sys.stderr)
        print("        说明录包时 FAST-LIO2 没发过这个话题", file=sys.stderr)
        return 2

    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message
    cls = get_message(types[TOPIC])

    chunks, frames, npts, bad = [], 0, 0, 0
    counts = {name: 0 for name in types}
    for topic, data in stream:
        counts[topic] = counts.get(topic, 0) + 1
        if topic != TOPIC:
            continue
        arr = frame_to_xyz(deserialize_message(data, cls))
        if arr is None:
            bad += 1
            continue
        if arr.shape[0]:
            chunks.append(arr)
            frames += 1
            npts += arr.shape[0]

    for name, c in sorted(counts.items()):
        print(f"[info] {name:24s} {c:6d} 条" + ("" if c else "   <-- 0 条"))
    if bad:
        print(f"[warn] {bad} 帧解析为空（字段缺失或 data 长度不对）")

    if not chunks or npts == 0:
        print(f"[ERROR] {TOPIC} 有 {counts.get(TOPIC, 0)} 条消息，但没有一个可用点",
              file=sys.stderr)
        print("        多半是录制期间 LIO 还没收敛 / 退化", file=sys.stderr)
        return 3

    pts = np.vstack(chunks)
    hdr = (
        "# .PCD v0.7 - Point Cloud Data file format\n"
        "VERSION 0.7\nFIELDS x y z intensity\nSIZE 4 4 4 4\nTYPE F F F F\n"
        "COUNT 1 1 1 1\n"
        f"WIDTH {npts}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\n"
        f"POINTS {npts}\nDATA binary\n"
    )
    with open(out, "wb") as f:
        f.write(hdr.encode())
        f.write(np.ascontiguousarray(pts, dtype=np.float32).tobytes())

    mb = os.path.getsize(out) / 1048576.0
    print(f"[OK] {frames} 帧, {npts} 点 -> {out}  ({mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
