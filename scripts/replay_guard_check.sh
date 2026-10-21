#!/usr/bin/env bash
# 离线回归：用真实 bag 回放，检查 imu-guard 是否拦下尖峰
# 用法: ./scripts/replay_guard_check.sh <bag目录> [回放秒数=45]
set +u
BAG="${1:?用法: $0 <bag目录> [秒数]}"
SECS="${2:-45}"
cd "$(dirname "$0")/.." || exit 1
mkdir -p logs
LOG="logs/guard_replay.log"
: >"$LOG"

source /opt/ros/humble/setup.bash
source install/local_setup.bash

echo "bag: $BAG"
echo "日志: $(pwd)/$LOG"

ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=true \
    >>"$LOG" 2>&1 &
sleep 6

if ! pgrep -f fastlio2_mapping >/dev/null; then
    echo "建图节点没起来，看 $LOG"
    tail -20 "$LOG"
    exit 1
fi
echo "建图节点已启动，开始回放 ${SECS}s ..."

timeout "${SECS}" ros2 bag play "$BAG" --topics /livox/lidar /livox/imu --clock \
    >>"$LOG" 2>&1
sleep 3
pkill -f fastlio2_mapping 2>/dev/null
pkill -f "ros2 launch go2_fastlio" 2>/dev/null

echo
echo "=== imu-guard 触发 ==="
G=$(grep -c "IMU\]\[guard" "$LOG" 2>/dev/null || true)
echo "次数: ${G:-0}"
grep "IMU\]\[guard" "$LOG" 2>/dev/null | head -8
echo
echo "=== gap-fix / 崩溃 / nan ==="
echo "gap-fix: $(grep -c 'gap-fix' "$LOG" 2>/dev/null || echo 0)"
grep -iE "nan|inf|segmentation|terminate called" "$LOG" 2>/dev/null | head -3 || echo "无"
echo
echo "=== 地图点数（确认建图确实在跑）==="
grep -iE "point|frame|IMU Initial" "$LOG" 2>/dev/null | tail -6
