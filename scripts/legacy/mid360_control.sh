#!/bin/bash
# =============================================================
#  Mid360 交互式实时建图控制器
#  终端输入命令控制扫描的「开始 / 暂停 / 停止 / 退出」，
#  每次任务在 ~/bags/<开始时间> 目录下存放 rosbag 与 PCD。
#  启动时自动打开 RViz 可视化（可用 norviz 参数关闭）。
#
#  命令说明:
#    start  开始一次新扫描（创建以当前时间命名的任务目录，启动录包）
#    pause  暂停当前录包（rosbag 进程挂起，不丢数据）
#    resume 继续录包
#    stop   停止当前录包，并自动把点云转成 PCD 存入任务目录
#    status 查看当前状态
#    quit   退出整个程序（先 stop 再关闭驱动/建图/RViz）
#    help   显示命令列表
#
#  用法:
#    ./mid360_control.sh          # 完整流程（含 RViz）
#    ./mid360_control.sh norviz   # 不开 RViz（远程/无人值守）
# =============================================================

BASE_DIR="${MID360_BAG_DIR:-$HOME/bags}"
CTRL_DIR="$(cd "$(dirname "$0")" && pwd)"       # scripts/ 目录
WS_DIR="$(cd "$CTRL_DIR/.." && pwd)"            # 工作空间根（仓库根）
PCD_SCRIPT="$CTRL_DIR/bag_to_pcd.py"
ENV_CHECK_SCRIPT="$CTRL_DIR/env_check.sh"
LOG_DIR=/tmp/mid360_ctrl
mkdir -p "$LOG_DIR"

source /opt/ros/humble/setup.bash
# 优先用本仓库编译产物；若用户另有 ROS 工作空间可用 ROS_WS_INSTALL 覆盖
if [ -f "$WS_DIR/install/setup.bash" ]; then
    source "$WS_DIR/install/setup.bash"
elif [ -n "${ROS_WS_INSTALL:-}" ] && [ -f "$ROS_WS_INSTALL/setup.bash" ]; then
    source "$ROS_WS_INSTALL/setup.bash"
else
    echo "[WARN] 未找到 install/setup.bash，请先运行 ./setup.sh 或设置 ROS_WS_INSTALL"
fi
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/lib

# ---- RViz 开关 ----
WITH_RVIZ=1
for a in "$@"; do
    [ "$a" = "norviz" ] && WITH_RVIZ=0
done

# ---- 全局状态 ----
DRV_PID=""          # 驱动进程
MAP_PID=""          # 建图进程
REC_PID=""          # 录包进程
RVZ_PID=""          # RViz 进程
TASK_DIR=""         # 当前任务目录
REC_STATE="idle"    # idle / recording / paused
ENV_CHECKED=0       # 是否已做（或已跳过）首次环境检查

# 颜色
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'

log() { echo -e "$*"; }

# 清理残留进程
cleanup_procs() {
    [ -n "$REC_PID" ] && kill -9 $REC_PID 2>/dev/null
    [ -n "$RVZ_PID" ] && kill -9 $RVZ_PID 2>/dev/null
    [ -n "$MAP_PID" ] && kill -9 $MAP_PID 2>/dev/null
    [ -n "$DRV_PID" ] && kill -9 $DRV_PID 2>/dev/null
    pkill -9 -f fastlio2_mapping 2>/dev/null
    pkill -9 -f livox_ros_driver2_node 2>/dev/null
    pkill -9 -f "ros2 bag record" 2>/dev/null
    pkill -9 -f "rviz2" 2>/dev/null
}

start_driver_mapping() {
    log "${C}=== 启动 Livox 驱动 + FAST-LIO2 建图${N}"
    ros2 launch livox_ros_driver2 msg_MID360.launch.py > "$LOG_DIR/driver.log" 2>&1 &
    DRV_PID=$!
    sleep 5
    ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=false > "$LOG_DIR/mapping.log" 2>&1 &
    MAP_PID=$!
    sleep 5
    log "${G}驱动(PID $DRV_PID) + 建图(PID $MAP_PID) 已就绪${N}"

    if [ "$WITH_RVIZ" = "1" ]; then
        log "${C}=== 启动 RViz2 可视化 ===${N}"
        ros2 launch go2_fastlio rviz.launch.py > "$LOG_DIR/rviz.log" 2>&1 &
        RVZ_PID=$!
        sleep 3
        log "${G}RViz(PID $RVZ_PID) 已启动${N}"
    fi

    log "  驱动日志: $LOG_DIR/driver.log"
    log "  建图日志: $LOG_DIR/mapping.log"
    [ "$WITH_RVIZ" = "1" ] && log "  RViz 日志: $LOG_DIR/rviz.log"
}

# 首次 start 前询问并执行环境检查
ask_env_check() {
    [ "$ENV_CHECKED" = "1" ] && return 0
    ENV_CHECKED=1
    echo ""
    echo -e "${C}首次扫描前，是否需要做一次环境检查？${N}"
    echo -e "${C}  (y) 是 —— 扫描本机环境，判断是否满足实时建图要求${N}"
    echo -e "${C}  (n) 否 —— 跳过，直接开始扫描${N}"
    printf "${G}是否检查环境 [y/N]: ${N}"
    read -r ans
    case "$ans" in
        y|Y|yes|YES)
            echo ""
            if [ -x "$ENV_CHECK_SCRIPT" ]; then
                bash "$ENV_CHECK_SCRIPT"
            else
                log "${R}未找到环境检查脚本 $ENV_CHECK_SCRIPT${N}"
            fi
            echo ""
            ;;
        *)
            log "${Y}已跳过环境检查${N}"
            ;;
    esac
}

do_start() {
    if [ "$REC_STATE" = "recording" ] || [ "$REC_STATE" = "paused" ]; then
        log "${Y}当前已有进行中的任务（$TASK_DIR），请先 stop${N}"
        return
    fi

    # 首次 start 前询问是否做环境检查
    ask_env_check

    local ts; ts=$(date +%Y-%m-%d_%H-%M-%S)
    TASK_DIR="$BASE_DIR/$ts"
    mkdir -p "$TASK_DIR"
    log "${G}=== 开始扫描，任务目录: $TASK_DIR ===${N}"

    # 记录任务信息
    {
        echo "任务开始时间: $ts"
        echo "雷达: Mid360 @ 192.168.120.221"
        echo "录包话题: /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init"
    } > "$TASK_DIR/info.txt"

    ros2 bag record -o "$TASK_DIR/scan" \
        /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init \
        > "$TASK_DIR/record.log" 2>&1 &
    REC_PID=$!
    sleep 2
    REC_STATE="recording"
    log "  录包已启动 (PID $REC_PID)，rosbag 写入 $TASK_DIR/scan/"
}

do_pause() {
    if [ "$REC_STATE" != "recording" ]; then
        log "${Y}当前没有正在录制的任务（状态: $REC_STATE）${N}"
        return
    fi
    kill -STOP $REC_PID 2>/dev/null
    REC_STATE="paused"
    log "${Y}=== 已暂停录包（PID $REC_PID 已挂起）===${N}"
}

do_resume() {
    if [ "$REC_STATE" != "paused" ]; then
        log "${Y}当前没有暂停的任务（状态: $REC_STATE）${N}"
        return
    fi
    kill -CONT $REC_PID 2>/dev/null
    REC_STATE="recording"
    log "${G}=== 已继续录包 ===${N}"
}

do_stop() {
    if [ "$REC_STATE" = "idle" ]; then
        log "${Y}当前没有任务在录制${N}"
        return
    fi
    log "${Y}=== 停止录包并生成 PCD ===${N}"
    # 若处于暂停态，先恢复再停止，确保 rosbag 正常收尾
    [ "$REC_STATE" = "paused" ] && kill -CONT $REC_PID 2>/dev/null
    kill -INT $REC_PID 2>/dev/null
    # 等待 rosbag 正常退出（最多 10s）
    for i in $(seq 1 20); do
        kill -0 $REC_PID 2>/dev/null || break
        sleep 0.5
    done
    kill -0 $REC_PID 2>/dev/null && kill -9 $REC_PID 2>/dev/null
    REC_PID=""
    REC_STATE="idle"

    # 定位实际 bag 目录（rosbag 会在 scan/ 下生成 scan_0.db3 + metadata.yaml）
    local bagdir
    bagdir=$(find "$TASK_DIR" -name "metadata.yaml" -printf "%h\n" 2>/dev/null | head -1)
    if [ -z "$bagdir" ]; then
        log "${R}未找到录制的 bag（metadata.yaml），跳过 PCD 转换${N}"
        log "  任务目录: $TASK_DIR"
        TASK_DIR=""
        return
    fi

    log "  录包完成: $bagdir"
    log "${C}  转换点云 -> PCD ...${N}"
    # 用系统 python3 跑（有 rosbag2_py）
    if /usr/bin/python3 "$PCD_SCRIPT" "$bagdir" "$TASK_DIR/map.pcd" 2>/dev/null; then
        log "${G}  PCD 已保存: $TASK_DIR/map.pcd${N}"
    else
        log "${R}  PCD 转换失败（可能 /cloud_registered 无数据），请检查 record.log${N}"
    fi

    # 汇总任务目录
    log "${G}=== 任务完成，文件如下 ===${N}"
    ls -lh "$TASK_DIR"
    TASK_DIR=""
}

do_status() {
    echo -e "${C}--- 状态 ---${N}"
    echo "  驱动 PID: ${DRV_PID:-无}"
    echo "  建图 PID: ${MAP_PID:-无}"
    echo "  录包 PID: ${REC_PID:-无}"
    echo "  RViz PID: ${RVZ_PID:-无}"
    echo "  录包状态: $REC_STATE"
    echo "  当前任务: ${TASK_DIR:-无}"
    echo "  本次会话已生成任务目录:"
    ls -dt "$BASE_DIR"/202* 2>/dev/null | head -5 | sed 's/^/    /'
}

do_help() {
    echo -e "${C}可用命令:${N}"
    echo "  start  开始新扫描（首次会询问是否做环境检查）"
    echo "  pause  暂停录包"
    echo "  resume 继续录包"
    echo "  stop   停止录包并生成 PCD"
    echo "  status 查看状态"
    echo "  env    手动执行一次环境检查"
    echo "  quit   退出（自动 stop + 关闭驱动/建图/RViz）"
    echo "  help   显示本帮助"
}

do_env() {
    if [ -x "$ENV_CHECK_SCRIPT" ]; then
        bash "$ENV_CHECK_SCRIPT"
    else
        log "${R}未找到环境检查脚本 $ENV_CHECK_SCRIPT${N}"
    fi
}

do_quit() {
    [ "$REC_STATE" != "idle" ] && do_stop
    log "${Y}=== 关闭驱动 / 建图 / RViz ===${N}"
    [ -n "$MAP_PID" ] && kill -INT $MAP_PID 2>/dev/null
    sleep 5
    [ -n "$DRV_PID" ] && kill -INT $DRV_PID 2>/dev/null
    [ -n "$RVZ_PID" ] && kill -INT $RVZ_PID 2>/dev/null
    sleep 2
    cleanup_procs
    log "${G}已退出${N}"
}

# ================= 主流程 =================
trap 'do_quit; exit 0' INT TERM

cleanup_procs
start_driver_mapping

log ""
log "${C}========================================${N}"
log "${C} 交互式实时建图控制器已就绪${N}"
log "${C} 输入命令: start / pause / resume / stop / status / quit${N}"
log "${C}========================================${N}"

while true; do
    printf "${G}mid360> ${N}"
    read -r cmd || { do_quit; exit 0; }
    case "$cmd" in
        start)  do_start ;;
        pause)  do_pause ;;
        resume) do_resume ;;
        stop)   do_stop ;;
        status) do_status ;;
        env)    do_env ;;
        quit)   do_quit; exit 0 ;;
        help)   do_help ;;
        "")     ;;
        *)      log "${Y}未知命令 '$cmd'，输入 help 查看${N}" ;;
    esac
done
