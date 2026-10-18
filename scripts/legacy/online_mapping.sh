#!/bin/bash
# 在线实时建图一键启动脚本
# Mid360 网线直连 PC -> livox 驱动实时采集 -> fastlio2_mapping 实时建图 -> RViz2 预览 + 边录边存
#
# 前置：本机有线网卡已配置静态 IP 192.168.1.5/24（对应雷达 192.168.1.12）
#
# 用法：
#   ./online_mapping.sh              # 完整流程（驱动+建图+录包），Ctrl+C 结束并保存 PCD
#   ./online_mapping.sh norviz       # 不带 RViz（无人值守/远程）
#   ./online_mapping.sh norecord     # 只实时建图，不边录边存

set -u
WITH_RVIZ=1
WITH_RECORD=1
for a in "$@"; do
  case "$a" in
    norviz)   WITH_RVIZ=0 ;;
    norecord) WITH_RECORD=0 ;;
  esac
done

source /opt/ros/humble/setup.bash
# 你原来的单机建图工作空间（按需改，或导出 ROS2_WS 指定）
ROS2_WS="${ROS2_WS:-$HOME/ros2_ws}"
[ -f "$ROS2_WS/install/setup.bash" ] && source "$ROS2_WS/install/setup.bash"
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/lib

REC_DIR="${REC_DIR:-$HOME/bags/online}"
mkdir -p "$REC_DIR"

echo "=== [1/3] 启动 Livox 驱动（实时采集）==="
ros2 launch livox_ros_driver2 msg_MID360.launch.py > /tmp/livox_driver.log 2>&1 &
DRV=$!
sleep 4

echo "=== [2/3] 启动 FAST-LIO2 建图（实时模式 use_sim_time:=false）==="
ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=false > /tmp/fastlio_mapping.log 2>&1 &
MAP=$!
sleep 4

echo "=== [3/3] 边录边存（原始 livox 数据，可事后复现）==="
if [ "$WITH_RECORD" = "1" ]; then
  ros2 bag record -o "$REC_DIR/online" /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init > /tmp/record.log 2>&1 &
  REC=$!
fi

if [ "$WITH_RVIZ" = "1" ]; then
  echo "=== 启动 RViz2 预览（另开终端也可手动 ros2 launch go2_fastlio rviz.launch.py）==="
  ros2 launch go2_fastlio rviz.launch.py > /tmp/rviz.log 2>&1 &
  RVZ=$!
fi

echo ""
echo "=== 实时建图运行中 ==="
echo "  驱动日志:  /tmp/livox_driver.log"
echo "  建图日志:  /tmp/fastlio_mapping.log"
echo "  录包目录:  $REC_DIR"
echo "  按 Ctrl+C 结束并保存地图"
echo ""

trap 'echo "=== 收到退出，保存地图 ==="; kill -INT $MAP $REC $RVZ 2>/dev/null; sleep 8; kill -9 $MAP $REC $RVZ $DRV 2>/dev/null; exit 0' INT

wait $MAP
