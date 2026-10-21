"""kf_core 的回归测试。跑法：

    /usr/bin/python3 -m tools.sim.test_kf_core
    # 或
    /usr/bin/python3 tools/sim/test_kf_core.py

覆盖四件事：
1. 纯平移时的触发间距正确
2. 原地旋转也能触发（只靠平移会漏掉环视采集）
3. 静止时靠 max_gap 兜底
4. OpenCV -> OpenGL 的翻轴方向正确（这处错了训练会整体上下颠倒）
"""

import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.sim.kf_core import (  # noqa: E402
    KFConfig,
    c2w_cv_to_opengl,
    coverage_report,
    invert,
    pose_delta,
    rot_angle,
    select_keyframes,
)


def _look(eye, target):
    """OpenCV 约定的 c2w：z 轴指向前方，y 轴指向下方（世界为 z-up）。"""
    eye = np.asarray(eye, dtype=np.float64)
    z = np.asarray(target, dtype=np.float64) - eye
    z /= np.linalg.norm(z)
    x = np.cross(z, np.array([0.0, 0.0, 1.0]))
    if np.linalg.norm(x) < 1e-6:
        x = np.array([1.0, 0.0, 0.0])
    x /= np.linalg.norm(x)
    y = np.cross(z, x)
    T = np.eye(4)
    T[:3, 0], T[:3, 1], T[:3, 2] = x, y, z
    T[:3, 3] = eye
    return T


def _T(x=0.0, y=0.0, z=0.0, yaw=0.0):
    """构造 c2w。yaw 是**水平面内**的朝向角（世界 z-up，所以绕世界 z 转）。

    别用绕相机 z 轴（光轴）旋转来模拟转头 —— 那是 roll，光轴方向不变，
    yaw_coverage_deg 会正确返回 0，看起来像覆盖率算错了。
    """
    eye = np.array([x, y, z], dtype=np.float64)
    target = eye + np.array([math.cos(yaw), math.sin(yaw), 0.0])
    return _look(eye, target)


def test_translation_spacing():
    """每帧前进 0.05 m，阈值 0.15 m -> 每 3 帧取一帧。"""
    poses = [_T(x=0.05 * i) for i in range(31)]
    times = [0.1 * i for i in range(31)]
    res = select_keyframes(poses, times, KFConfig(min_trans_m=0.15, max_gap_s=99))
    assert res.indices == [0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30], res.indices
    print(f"  translation spacing ok: {len(res)} frames from 31")


def test_rotation_triggers():
    """原地每帧转 2 度，累计 5 度即触发 -> 间距 3 帧。"""
    poses = [_T(yaw=math.radians(2 * i)) for i in range(30)]
    times = [0.1 * i for i in range(30)]
    res = select_keyframes(poses, times, KFConfig(min_trans_m=0.5, min_rot_deg=5.0, max_gap_s=99))
    assert len(res) > 8, f"only {len(res)} frames, rotation rule likely broken"
    for i in res.indices[1:]:
        dt, drot = pose_delta(poses[res.indices[res.indices.index(i) - 1]], poses[i])
        assert math.degrees(drot) >= 4.9 or dt >= 0.5
    span = coverage_report(poses, times)["yaw_coverage_deg"]
    assert span > 50, f"yaw coverage {span} deg looks wrong"
    print(f"  rotation trigger ok: {len(res)} frames, yaw span {span:.0f} deg")


def test_static_fallback():
    """完全静止 + 阈值都很大 -> 只剩 max_gap 兜底。"""
    poses = [_T() for _ in range(100)]
    times = [0.1 * i for i in range(100)]
    res = select_keyframes(poses, times, KFConfig(min_trans_m=9, min_rot_deg=90, max_gap_s=3.0))
    assert len(res) >= 3, f"static fallback failed: {len(res)}"
    assert all(t <= 3.05 for t in np.diff([times[i] for i in res.indices]))
    print(f"  static fallback ok: {len(res)} frames over 10 s")


def test_opengl_flip():
    """OpenCV 前方 +z 必须变成 OpenGL 的 -z；y 轴取反。"""
    T = _T()
    gl = c2w_cv_to_opengl(T)
    fwd_cv = T[:3, :3] @ np.array([0, 0, 1.0])
    fwd_gl = gl[:3, :3] @ np.array([0, 0, 1.0])
    assert np.allclose(fwd_gl, -fwd_cv), (fwd_gl, fwd_cv)
    up_cv = T[:3, :3] @ np.array([0, 1.0, 0])
    up_gl = gl[:3, :3] @ np.array([0, 1.0, 0])
    assert np.allclose(up_gl, -up_cv), (up_gl, up_cv)
    print("  opencv->opengl flip ok (+z -> -z, +y -> -y)")


def test_invert_and_angle():
    T = _T(1.5, -2.0, 0.3, yaw=0.7)
    I = T @ invert(T)
    assert np.allclose(I, np.eye(4), atol=1e-9)
    assert abs(rot_angle(np.eye(4))) < 1e-6
    R90 = _T(yaw=math.pi / 2)[:3, :3]
    assert abs(math.degrees(rot_angle(np.block([[R90, np.zeros((3, 1))], [np.zeros((1, 3)), np.ones((1, 1))]]))) - 90) < 0.01
    print("  invert / rot_angle ok")


def test_coverage():
    poses = [_T(x=0.1 * i) for i in range(20)]
    rep = coverage_report(poses, [0.1 * i for i in range(20)])
    assert abs(rep["path_m"] - 1.9) < 1e-6, rep["path_m"]
    assert rep["yaw_coverage_deg"] < 1.0, rep["yaw_coverage_deg"]
    print(f"  coverage ok: path={rep['path_m']:.2f} m, yaw span={rep['yaw_coverage_deg']:.1f} deg")


if __name__ == "__main__":
    print("kf_core regression:")
    test_translation_spacing()
    test_rotation_triggers()
    test_static_fallback()
    test_opengl_flip()
    test_invert_and_angle()
    test_coverage()
    print("all passed")
