#!/usr/bin/env bash
# 主机端：把 bag 预处理成 DVLCalib 能吃的 calib_data/。
#
#   ./preprocess.sh [bag父目录] [输出目录]
#   ./preprocess.sh ~/tmp/dvlc/bags ~/tmp/dvlc/calib_data
#
# bag 父目录下每个子目录是一个 ros2 bag（含 metadata.yaml）。
set -eu

DATA=${1:-$HOME/tmp/dvlc/bags}
DST=${2:-$HOME/tmp/dvlc/calib_data}

# 相机内参（来自 report.txt：1280x720 棋盘格 40 张，RMS 1.09 px，带畸变模型）
INT="903.8353,905.4474,654.1131,363.7572"
DIST="0.131003,-0.416436,-0.000653,0.004949,0.380354"

export LD_LIBRARY_PATH=$HOME/dvlc_deps/lib:$HOME/dvlc_ws/install/direct_visual_lidar_calibration/lib:${LD_LIBRARY_PATH:-}
BIN=$HOME/dvlc_ws/install/direct_visual_lidar_calibration/lib/direct_visual_lidar_calibration/preprocess

mkdir -p "$DST"
echo "data_path = $DATA"
echo "dst_path  = $DST"

"$BIN" \
  --data_path "$DATA" \
  --dst_path "$DST" \
  --image_topic /calib/image \
  --points_topic /livox/lidar \
  --camera_model plumb_bob \
  --camera_intrinsics "$INT" \
  --camera_distortion_coeffs "$DIST"

echo
echo "=== 产出 ==="
ls -lh "$DST"
echo
echo "判据：每个包都有 <包名>.png 和 <包名>.ply 就算过。"
echo "日志里 'LiDAR FoV' 是凸包估出来的假象（Mid360 会报 ~173°），不用管。"
