#!/usr/bin/env bash
# 主机端：跑 NID 优化。
#
#   ./calibrate.sh [calib_data目录] [bfgs|nm]
#
# 前提：calib_data/calib.json 里已经有 results.init_T_lidar_camera。
# ⚠ 方向：T_lidar_camera 是 camera->lidar（p_lidar = T * p_camera）。
#   自己按 p_cam = R * p_lidar 算的旋转，写进去必须取转置（四元数取共轭）。
#
# 结果写回 calib_data/calib.json 的 results.T_lidar_camera。
# 先看 Ceres 最后的 f（= NID²）：f < 0.5 才值得信；f ≈ 0.98 就是没收敛。
set -eu

DIR=${1:-$HOME/tmp/dvlc/calib_data}
MODE=${2:-bfgs}

export LD_LIBRARY_PATH=$HOME/dvlc_deps/lib:$HOME/dvlc_ws/install/direct_visual_lidar_calibration/lib:${LD_LIBRARY_PATH:-}
BIN=$HOME/dvlc_ws/install/direct_visual_lidar_calibration/lib/direct_visual_lidar_calibration/calibrate
LOG=$DIR/../calibrate_$(date +%H%M%S).log

if [ ! -f "$DIR/calib.json" ]; then
  echo "没有 $DIR/calib.json，先跑 preprocess.sh" >&2
  exit 1
fi
if ! grep -q init_T_lidar_camera "$DIR/calib.json"; then
  echo "calib.json 里没有 results.init_T_lidar_camera，先做初值（见文档 4.3）" >&2
  exit 1
fi

case "$MODE" in
  bfgs) ARGS="--registration_type nid_bfgs --nid_bins 16" ;;
  nm)   ARGS="--registration_type nid_nelder_mead --nelder_mead_init_step 0.05 --nid_bins 16" ;;
  *)    echo "MODE 只能是 bfgs 或 nm" >&2; exit 1 ;;
esac

echo "log -> $LOG"
set +e
"$BIN" "$DIR" --background --auto_quit $ARGS 2>&1 | tee "$LOG"
set -e

echo
echo "=== 最优 f ==="
grep -oE "f: [0-9.e+-]+" "$LOG" | awk '{print $2}' | sort -g | head -3
echo
echo "=== 结果 T_lidar_camera ==="
python3 - "$DIR/calib.json" <<'PY'
import json, sys, math
d = json.load(open(sys.argv[1]))
r = d.get("results", {})
if "T_lidar_camera" not in r:
    print("没有 results.T_lidar_camera —— 优化没跑到写结果那一步")
    sys.exit(0)
v = r["T_lidar_camera"]
print("t = [%.4f, %.4f, %.4f] m  (相机原点在雷达系下的位置)" % tuple(v[:3]))
qx, qy, qz, qw = v[3:]
print("q = [%.6f, %.6f, %.6f, %.6f]  (|q|=%.6f)" % (qx, qy, qz, qw,
      math.sqrt(qx*qx + qy*qy + qz*qz + qw*qw)))
print()
print("下一步必须肉眼验证（外参差 1-2 cm 整幅就双重影）：")
print("  ./proj_check.py <bag目录> /tmp/final_check.png " + " ".join("%.6f" % x for x in v))
PY
