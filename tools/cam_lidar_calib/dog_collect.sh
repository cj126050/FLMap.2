#!/usr/bin/env bash
# 狗端：起 MID360 + D435i，把彩色图降频后录一包标定数据。
#
#   ./dog_collect.sh <包名> [秒数]
#   ./dog_collect.sh calib_02 15
#
# 产出 /tmp/calib_bags/<包名>/ 。录完把这整个目录 scp 回主机。
set -u

BAG=${1:?用法: ./dog_collect.sh <包名> [秒数]}
DUR=${2:-15}
OUT=/tmp/calib_bags/$BAG
WS_LIVOX=${WS_LIVOX:-$HOME/livox_ws}
WS_RS=${WS_RS:-$HOME/ros2_ws}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== 清理旧进程 =="
# 注意：不要用 pkill -f "<长字符串>"，会匹配到 ssh/bash 自己的命令行导致自杀
pkill -x livox_ros_driver2_node 2>/dev/null
pkill -x realsense2_camera_node 2>/dev/null
pkill -x rs_launch.py 2>/dev/null
pkill -f "img_relay.py" 2>/dev/null
sleep 1

echo "== 起 MID360（xfer_format:=0 才会发 PointCloud2）=="
source /opt/ros/foxy/setup.bash
[ -f "$WS_LIVOX/install/setup.bash" ] && source "$WS_LIVOX/install/setup.bash"
nohup ros2 run livox_ros_driver2 livox_ros_driver2_node \
  --ros-args -p xfer_format:=0 -p multi_topic:=0 -p data_src:=0 \
            -p publish_freq:=10.0 -p output_data_type:=0 -p frame_id:=livox_frame \
  > /tmp/livox.log 2>&1 &
sleep 3

echo "== 起 D435i（1280x720，彩色 30fps）=="
[ -f "$WS_RS/install/setup.bash" ] && source "$WS_RS/install/setup.bash"
nohup ros2 launch realsense2_camera rs_launch.py \
  enable_color:=true rgb_camera.color_profile:=1280x720x30 \
  enable_depth:=false pointcloud.enable:=false \
  > /tmp/realsense.log 2>&1 &
sleep 5

echo "== 起图像降频转发 30fps -> /calib/image 1Hz =="
nohup python3 "$HERE/img_relay.py" > /tmp/img_relay.log 2>&1 &
sleep 2

echo "== 检查话题 =="
ros2 topic list | grep -E "livox/lidar|calib/image|camera/color" || true
ros2 topic hz /livox/lidar --window 10 2>/dev/null &
HZPID=$!
sleep 3
kill $HZPID 2>/dev/null

mkdir -p "$OUT"
echo "== 录 $DUR 秒到 $OUT =="
timeout $((DUR + 5)) ros2 bag record -o "$OUT" \
  --qos-profile-overrides-path "$HERE/qos.yaml" \
  /livox/lidar /calib/image

echo "== 完成 =="
du -sh "$OUT" 2>/dev/null
ls -l "$OUT" 2>/dev/null
echo
echo "下一步：scp -r unitree@<狗IP>:$OUT ~/tmp/dvlc/bags/"
echo "并在狗上停掉传感器：pkill -x livox_ros_driver2_node; pkill -f img_relay.py"
