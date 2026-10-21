"""关键帧筛选与位姿工具 —— 真实端与模拟端共用同一份实现。

设计约束：本模块不 import rclpy / rospy / torch。
理由：模拟链路（tools/sim/）和狗端（flmap_bridge 侧）必须跑同一份逻辑，
否则"模拟通过"不能推出"现场通过"。任何 ROS 依赖都应留在调用方。

位姿约定：4x4 的 c2w（camera-to-world），相机系为 OpenCV 约定
（x 右、y 下、z 前）。NEED_OPENGL 只在上交 nerfstudio 时做一次转换。
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from typing import Iterable, Sequence

import numpy as np

# OpenCV 相机系 -> OpenGL 相机系（y 翻、z 翻）
FLIP_YZ = np.diag([1.0, -1.0, -1.0, 1.0])

# 阈值比较的容差。位姿来自 6 位小数的里程计，0.05*3 与 0.05*6 的差算出来是
# 0.14999999999999997，严格 >= 会让"刚好等于阈值"的一帧随机丢失，表现为关键帧
# 间距时紧时松。留 1 µm 的余量比每次比较都加 round() 干净。
EPS = 1e-6


# --------------------------------------------------------------------------
# 位姿基础
# --------------------------------------------------------------------------
def rot_angle(R: np.ndarray) -> float:
    """旋转矩阵对应的转角（弧度）。夹紧 trace 避免 acos 溢出。"""
    c = (float(np.trace(R[:3, :3])) - 1.0) / 2.0
    return math.acos(max(-1.0, min(1.0, c)))


def pose_delta(T_a: np.ndarray, T_b: np.ndarray) -> tuple[float, float]:
    """两个 c2w 之间的（平移米数, 转角弧度）。"""
    dt = float(np.linalg.norm(T_b[:3, 3] - T_a[:3, 3]))
    R_rel = T_a[:3, :3].T @ T_b[:3, :3]
    return dt, rot_angle(R_rel)


def invert(T: np.ndarray) -> np.ndarray:
    R, t = T[:3, :3], T[:3, 3]
    out = np.eye(4)
    out[:3, :3] = R.T
    out[:3, 3] = -R.T @ t
    return out


def c2w_cv_to_opengl(T_c2w_cv: np.ndarray) -> np.ndarray:
    """c2w（OpenCV 相机系）转 c2w（OpenGL 相机系），供 nerfstudio 使用。

    基变换：用 FLIP_YZ 右乘，等价于把相机的 y、z 轴取反。
    验证：OpenCV 的前方 +z 在结果里变成 -z（OpenGL 的 forward），符合预期。
    """
    return np.asarray(T_c2w_cv, dtype=np.float64) @ FLIP_YZ


# --------------------------------------------------------------------------
# 关键帧筛选
# --------------------------------------------------------------------------
@dataclass
class KFConfig:
    """触发阈值的默认值来自 docs/15 §3.2 B2 的推导（720p / 水平 FOV 90°）。"""

    min_trans_m: float = 0.15      # 相邻关键帧最小平移
    min_rot_deg: float = 5.0       # 相邻关键帧最小转角
    max_gap_s: float = 3.0         # 超过这么久强制存一帧，防静止时时间轴断裂
    start_with_first: bool = True


@dataclass
class KFResult:
    indices: list[int] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.indices)


def select_keyframes(
    poses_c2w: Sequence[np.ndarray],
    times_s: Sequence[float],
    cfg: KFConfig | None = None,
) -> KFResult:
    """按空间采样挑关键帧，不按固定帧率。

    判定顺序（先命中先算）：
      1. 平移 >= min_trans_m
      2. 转角 >= min_rot_deg
      3. 距上一关键帧 >= max_gap_s
    两条都不满足就丢弃 —— 这正是"相机停在原地"时不产生冗余帧的原因。
    """
    cfg = cfg or KFConfig()
    n = len(poses_c2w)
    if n == 0:
        return KFResult()
    if len(times_s) != n:
        raise ValueError(f"poses({n}) 与 times({len(times_s)}) 长度不一致")

    res = KFResult()
    if cfg.start_with_first:
        res.indices.append(0)
        res.reasons.append("first")

    last = 0
    for i in range(1, n):
        dt, drot = pose_delta(poses_c2w[last], poses_c2w[i])
        dt_gap = times_s[i] - times_s[last]
        reason = ""
        if dt >= cfg.min_trans_m - EPS:
            reason = f"trans={dt:.2f}m"
        elif math.degrees(drot) >= cfg.min_rot_deg - 1e-9:
            reason = f"rot={math.degrees(drot):.1f}deg"
        elif dt_gap >= cfg.max_gap_s - EPS:
            reason = f"gap={dt_gap:.1f}s"
        if reason:
            res.indices.append(i)
            res.reasons.append(reason)
            last = i

    return res


# --------------------------------------------------------------------------
# 轨迹与覆盖率统计（验收用）
# --------------------------------------------------------------------------
def path_length(poses_c2w: Iterable[np.ndarray]) -> float:
    ts = [np.asarray(T)[:3, 3] for T in poses_c2w]
    return float(sum(np.linalg.norm(b - a) for a, b in zip(ts, ts[1:])))


def yaw_coverage_deg(poses_c2w: Sequence[np.ndarray]) -> float:
    """水平朝向覆盖的角度跨度。查"只朝一个方向扫"这类采集缺陷。

    两个容易搞错的地方，都踩过：
    1. `fwd` 是**世界系**向量（c2w 的旋转已把相机 z 轴带到世界系），
       而 FAST-LIO2 的 world 是 z-up，所以水平面是 x-y，
       朝向角 = atan2(fwd_y, fwd_x)。用 fwd_z 得到的是俯仰，转一圈也不变。
    2. 相机系本身是 y-down，但这一点已在 c2w 里消化掉了，这里不需要再翻转。
    """

    def yaw(T: np.ndarray) -> float:
        fwd = np.asarray(T)[:3, :3] @ np.array([0.0, 0.0, 1.0])
        horiz = math.hypot(fwd[0], fwd[1])
        if horiz < 0.2:      # 光轴接近竖直（俯拍），水平朝向无意义
            return 0.0
        return math.atan2(fwd[1], fwd[0])

    if len(poses_c2w) < 2:
        return 0.0
    ys = np.unwrap([yaw(T) for T in poses_c2w])
    return float(math.degrees(ys.max() - ys.min()))


def coverage_report(poses_c2w: Sequence[np.ndarray], times_s: Sequence[float]) -> dict:
    """给 B6 验收用的一页统计。真实场景同样适用（不需要 GT）。"""
    if len(poses_c2w) < 2:
        return {"frames": len(poses_c2w)}
    steps = [
        float(np.linalg.norm(np.asarray(b)[:3, 3] - np.asarray(a)[:3, 3]))
        for a, b in zip(poses_c2w, poses_c2w[1:])
    ]
    return {
        "frames": len(poses_c2w),
        "duration_s": float(times_s[-1] - times_s[0]),
        "path_m": path_length(poses_c2w),
        "yaw_coverage_deg": yaw_coverage_deg(poses_c2w),
        "median_step_m": float(np.median(steps)),
        "max_step_m": float(np.max(steps)),
    }


# --------------------------------------------------------------------------
# 位姿 I/O
# --------------------------------------------------------------------------
def load_poses_txt(path: str) -> np.ndarray:
    """读每行 16 个数的 4x4 c2w（行优先）。"""
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            vals = [float(x) for x in line.split()]
            if len(vals) != 16:
                continue
            rows.append(np.array(vals).reshape(4, 4))
    if not rows:
        raise ValueError(f"{path} 里没有 4x4 位姿")
    return np.stack(rows)


def write_transforms_json(
    out_path: str,
    frames: list[dict],
    K: np.ndarray,
    dist: Sequence[float],
    width: int,
    height: int,
    extra: dict | None = None,
) -> None:
    """写 nerfstudio 的 transforms.json。

    frames 里的 transform_matrix 必须是 OpenGL 约定的 c2w —— 调用方负责转换，
    本函数只做序列化，避免隐式转换带来的双重翻转。
    """
    payload = {
        "camera_model": "OPENCV",
        "fl_x": float(K[0, 0]),
        "fl_y": float(K[1, 1]),
        "cx": float(K[0, 2]),
        "cy": float(K[1, 2]),
        "w": int(width),
        "h": int(height),
        "k1": float(dist[0]) if len(dist) > 0 else 0.0,
        "k2": float(dist[1]) if len(dist) > 1 else 0.0,
        "p1": float(dist[2]) if len(dist) > 2 else 0.0,
        "p2": float(dist[3]) if len(dist) > 3 else 0.0,
        "frames": frames,
    }
    if extra:
        payload.update(extra)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
