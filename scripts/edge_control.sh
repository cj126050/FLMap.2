#!/bin/bash
# =============================================================
#  edge_control.sh —— 狗端交互式建图控制台（不启动 RViz）
#
#  和原版 mid360_control.sh 的区别：
#    1. 不启 RViz —— 可视化在 PC 端做（见 scripts/pc_view.sh）
#    2. 多起一个 flmap_bridge，把全分辨率点云瘦身后发给 PC
#    3. 多了 link 命令，现场查链路质量（网口速率 + 到 PC 的 RTT）
#
#  ★ 本文件在 FLMap.2（无线包）和 FLMap.3（有线包）里是**同一份**。
#    链路差异（PC 地址、要看的网口、失败提示）全部来自 scripts/lib_link.sh。
#
#  命令:
#    start   开始一次新扫描（建任务目录 + 录包）
#    pause   暂停录包        resume 继续录包
#    stop    停止录包并导出 PCD
#    status  进程 / 话题 / 流量状态
#    link    链路体检（网口/无线状态 + 到 PC 的 RTT）
#    stats   bridge 输出频率与点数
#    quit    退出（先 stop，再关节点）
#
#  用法:
#    ./scripts/edge_control.sh              # 完整流程（交互，现场用）
#    ./scripts/edge_control.sh --no-bag     # 只建图不录包（省磁盘，调参时用）
#    ./scripts/edge_control.sh --auto 90    # 无人值守：录 90 秒 → 自动 stop/导出 → 退出
#
#  --auto 是为「一条命令跑完」和自动化验收加的：它不读 stdin，所以可以被
#  ssh 直接调用（ssh 的 stdin 是管道，交互模式读到 EOF 会立刻 do_quit）。
#  结尾会打印一行 TASK_DIR=<目录>，供 PC 端抓取后 scp。
# =============================================================

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 链路层：PC 地址、网口清单、提示语都由 lib_link.sh 提供。
# 本脚本在无线包/有线包里是同一份，不许在这里出现具体网段。
# shellcheck source=lib_link.sh
[ -f "$REPO_DIR/scripts/lib_link.sh" ] && source "$REPO_DIR/scripts/lib_link.sh"
LOG_DIR="${LOG_DIR:-/tmp/flmap_edge}"
BAG_DIR="${FLMAP_BAG_DIR:-$HOME/bags}"
if declare -F link_pc_addr >/dev/null 2>&1; then
    PC_IP="${PC_IP:-$(link_pc_addr)}"
else
    PC_IP="${PC_IP:-}"   # lib_link.sh 缺席时不猜地址，宁可空着
fi
mkdir -p "$LOG_DIR"

# ---- 环境：自动识别 Foxy（狗）/ Humble（开发机）----
for d in foxy humble; do
    if [ -f "/opt/ros/$d/setup.bash" ]; then
        # shellcheck disable=SC1090
        source "/opt/ros/$d/setup.bash"
        break
    fi
done
if [ -f "$REPO_DIR/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/install/setup.bash"
else
    echo "[ERROR] 没找到 $REPO_DIR/install/setup.bash —— 先在仓库根目录跑 ./setup.sh"
    exit 1
fi

export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"     # 避开宇树自用的 0 域
export ROS_LOCALHOST_ONLY=0
export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"

# 狗端 ~/.bashrc 里那段 fishros 初始化（登录时问 ros:foxy(1) noetic(2) ?）
# 选 1 会顺带 export CYCLONEDDS_URI=~/cyclonedds_ws/cyclonedds.xml。
# 那份 xml 用的是 CycloneDDS 0.9+ 的 <Interfaces> 语法，而狗端装的是 0.7.0，
# 载入时报 "Domain/General: Interfaces: unknown element"，
# 然后 rmw_create_node 失败、节点一启动就退出 —— 报错还藏在 launch 日志里。
#
# 但也不能就这样让它"自己挑网卡"：多网卡时 CycloneDDS 会打印
#   using network interface eth0 (udp/192.168.123.18) selected arbitrarily from: eth0, docker0, wlan0
# 挑错卡时多播只发在那一段上，主机的 RViz 永远发现不了桥 —— 现象是
# PC 端 `ros2 topic hz /flmap/cloud` 报 "does not appear to be published yet"，
# 而狗端本机一切正常。所以这里统一生成一份只绑一张卡的配置：
# dds_bind.sh 按"到链路目标的路由"选卡，与链路类型无关。
# 要保留自己那份：FLMAP_KEEP_CYCLONEDDS=1 ./scripts/edge_control.sh
if [ "${FLMAP_KEEP_CYCLONEDDS:-0}" = "1" ]; then
    [ -n "${CYCLONEDDS_URI:-}" ] && echo "[info] 沿用继承来的 CYCLONEDDS_URI=$CYCLONEDDS_URI"
elif DDS_XML=$(bash "$REPO_DIR/scripts/dds_bind.sh" dog 2>/dev/null); then
    export CYCLONEDDS_URI="file://$DDS_XML"
    echo "[info] DDS 绑定: $(sed -n 's:.*<NetworkInterfaceAddress>\(.*\)</NetworkInterfaceAddress>.*:\1:p' "$DDS_XML")"
else
    unset CYCLONEDDS_URI
    echo "[warn] 没生成 DDS 绑定配置，回退到 CycloneDDS 自动选网卡（可能选错网段）"
fi

WITH_BAG=1
AUTO_SEC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-bag) WITH_BAG=0; shift ;;
        --auto)   AUTO_SEC="${2:-60}"; shift; [ $# -gt 0 ] && shift ;;
        --auto=*) AUTO_SEC="${1#*=}"; shift ;;
        # `edge_control.sh status` 这类一次性子命令要原样留给下面的 case 分发，
        # 所以只吃掉已知的启动选项，别的参数一概不动。
        *) break ;;
    esac
done

DRV_PID=""; MAP_PID=""; BRG_PID=""; REC_PID=""
TASK_DIR=""; REC_STATE="idle"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
log() { echo -e "$*"; }

cleanup() {
    for p in "$REC_PID" "$BRG_PID" "$MAP_PID" "$DRV_PID"; do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    done
    pkill -9 -f flmap_bridge_node 2>/dev/null
    pkill -9 -f fastlio2_mapping 2>/dev/null
    pkill -9 -f livox_ros_driver2_node 2>/dev/null
    pkill -9 -f "ros2 bag record" 2>/dev/null
}

start_nodes() {
    log "${C}=== 启动 Livox 驱动${N}"
    ros2 launch livox_ros_driver2 msg_MID360_launch.py > "$LOG_DIR/driver.log" 2>&1 &
    DRV_PID=$!
    sleep 5

    log "${C}=== 启动 FAST-LIO2（use_sim_time=false）${N}"
    ros2 launch go2_fastlio mapping_mid360_go2.launch.py use_sim_time:=false > "$LOG_DIR/mapping.log" 2>&1 &
    MAP_PID=$!
    sleep 4

    log "${C}=== 启动瘦身桥（发给 PC）${N}"
    # 必须显式传 params-file：节点代码里的默认值是保守值，真正的调参在
    # src/flmap_bridge/config/bridge_default.yaml（install 里是指向它的符号链接）。
    BRG_CFG="$(ros2 pkg prefix flmap_bridge 2>/dev/null)/share/flmap_bridge/config/bridge_default.yaml"
    ros2 run flmap_bridge flmap_bridge_node --ros-args --params-file "$BRG_CFG" > "$LOG_DIR/bridge.log" 2>&1 &
    BRG_PID=$!
    sleep 2

    # 自检：雷达帧率是判断"到底有没有在出图"的唯一硬指标。
    # 但 LIO 刚启动时话题还没开始计数，`topic hz` 常常 6 秒内拿不到平均值 ——
    # 这时候报"暂无数据"会让人以为坏了。所以拿驱动日志兜底区分
    # "还没收敛（正常）" 和 "根本没连上雷达（要处理）"。
    local hz
    hz=$(PYTHONUNBUFFERED=1 timeout 6 ros2 topic hz /cloud_registered 2>/dev/null | grep -m1 "average rate" || true)
    if [ -n "$hz" ]; then
        log "${G}  /cloud_registered: $hz${N}"
    elif grep -q "successfully set lidar attitude" "$LOG_DIR/driver.log" 2>/dev/null; then
        log "${Y}  /cloud_registered 统计还没出（LIO 刚起，通常 10 秒内就正常）${N}"
        log "  驱动已连上雷达；用 status 再看一次"
    else
        log "${R}  /cloud_registered 无数据，且驱动未连上雷达${N}"
        log "  查雷达供电 / M8 航插 / IP 是否为 192.168.123.221（见 docs/08）"
    fi
    log "  日志: $LOG_DIR/{driver,mapping,bridge}.log"
}

ask_env_check() {
    [ "${ENV_CHECKED:-0}" = "1" ] && return 0
    ENV_CHECKED=1
    echo ""
    log "${C}扫描前是否做一次环境体检？(y/N)${N}"
    printf "${G}[y/N]: ${N}"
    read -r ans
    case "$ans" in
        y|Y) bash "$REPO_DIR/scripts/env_check.sh" ;;
        *)   log "${Y}已跳过${N}" ;;
    esac
}

do_start() {
    if [ "$REC_STATE" != "idle" ]; then
        log "${Y}已有进行中的任务（$TASK_DIR），先 stop${N}"; return
    fi
    ask_env_check
    local ts; ts=$(date +%Y-%m-%d_%H-%M-%S)
    TASK_DIR="$BAG_DIR/$ts"

    if [ "$WITH_BAG" = "1" ]; then
        mkdir -p "$TASK_DIR"
        {
            echo "开始时间: $ts"
            echo "主机: $(hostname)  ROS: ${ROS_DISTRO}  DOMAIN: $ROS_DOMAIN_ID"
            echo "话题: /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init /flmap/cloud"
        } > "$TASK_DIR/info.txt"
        ros2 bag record -o "$TASK_DIR/scan" \
            /livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init \
            > "$TASK_DIR/record.log" 2>&1 &
        REC_PID=$!
        sleep 2
        # 参数写错 / 目录已存在 / RMW 起不来时 record 是秒退的，
        # 不查这一下就会一路"录包中"到一个空目录，最后只剩一句导出失败。
        if ! kill -0 "$REC_PID" 2>/dev/null; then
            log "${R}录包进程已退出，record.log：${N}"
            tail -n 8 "$TASK_DIR/record.log" 2>/dev/null | sed 's/^/  /'
            REC_PID=""; REC_STATE="idle"; TASK_DIR=""; return
        fi
        REC_STATE="recording"
        log "${G}录包中 → $TASK_DIR/scan/  (PID $REC_PID)${N}"
    else
        REC_STATE="recording"
        log "${G}开始扫描（未录包，--no-bag）${N}"
    fi
}

do_pause() {
    [ "$REC_STATE" != "recording" ] && { log "${Y}当前没有在录${N}"; return; }
    [ -n "$REC_PID" ] && kill -STOP "$REC_PID" 2>/dev/null
    REC_STATE="paused"; log "${Y}已暂停${N}"
}

do_resume() {
    [ "$REC_STATE" != "paused" ] && { log "${Y}当前没有暂停的任务${N}"; return; }
    [ -n "$REC_PID" ] && kill -CONT "$REC_PID" 2>/dev/null
    REC_STATE="recording"; log "${G}已继续${N}"
}

do_stop() {
    [ "$REC_STATE" = "idle" ] && { log "${Y}没有在录${N}"; return; }
    if [ -n "$REC_PID" ]; then
        [ "$REC_STATE" = "paused" ] && kill -CONT "$REC_PID" 2>/dev/null
        kill -INT "$REC_PID" 2>/dev/null
        for _ in $(seq 1 20); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$REC_PID" 2>/dev/null
        REC_PID=""
    fi
    REC_STATE="idle"

    if [ -n "$TASK_DIR" ] && [ "$WITH_BAG" = "1" ]; then
        local exp_log
        exp_log="$TASK_DIR/pcd_export.log"
        # 目录整个交给脚本：它自己往下找 metadata.yaml / *.db3 / *.mcap，
        # 连 record 被 -9 掉、只剩 db3 没写 metadata 的包也能抢救出来。
        if /usr/bin/python3 "$REPO_DIR/scripts/bag_to_pcd.py" "$TASK_DIR" "$TASK_DIR/map.pcd" > "$exp_log" 2>&1; then
            log "${G}PCD 已导出: $TASK_DIR/map.pcd${N}"
        else
            # 这里以前是 2>/dev/null：真实报错（ImportError / 0 帧 / 打不开 bag）
            # 全被吞掉，只剩一句"可能没数据"，把排查方向带偏。
            log "${R}PCD 导出失败，原因：${N}"
            tail -n 8 "$exp_log" 2>/dev/null | sed 's/^/  /'
            log "  完整日志: $exp_log"
            if [ -n "$(find "$TASK_DIR" -name metadata.yaml -print -quit 2>/dev/null)" ]; then
                log "  bag 本体是好的，修好脚本/环境后可直接重导，不必重扫："
                log "    /usr/bin/python3 $REPO_DIR/scripts/bag_to_pcd.py $TASK_DIR $TASK_DIR/map.pcd"
            else
                log "  没有 metadata.yaml —— 录包没正常收尾，先看 $TASK_DIR/record.log"
            fi
        fi
        ls -lh "$TASK_DIR" | sed 's/^/  /'
    fi
    TASK_DIR=""
}

do_status() {
    # PID 变量只有控制台自己起的进程才有；非交互 `status` 是另一个进程，
    # 变量全是空，一律显示"无"会骗人（节点其实在跑）。所以为空的按进程名反查。
    _by_name() {
        local pat="$1"
        pgrep -f "$pat" 2>/dev/null | head -1
    }
    local drv map brg rec
    drv="${DRV_PID:-$(_by_name livox_ros_driver2_node)}"
    map="${MAP_PID:-$(_by_name fastlio2_mapping)}"
    brg="${BRG_PID:-$(_by_name flmap_bridge_node)}"
    rec="${REC_PID:-$(_by_name 'ros2 bag record')}"

    echo -e "${C}--- 进程 ---${N}"
    printf "  驱动 %-8s 建图 %-8s 桥 %-8s 录包 %-8s\n" \
        "${drv:-无}" "${map:-无}" "${brg:-无}" "${rec:-无}"
    if [ -z "$TASK_DIR" ]; then
        TASK_DIR=$(ls -dt ~/bags/*/ 2>/dev/null | head -1)
        TASK_DIR="${TASK_DIR%/}"
    fi
    echo "  录包状态: $REC_STATE   任务: ${TASK_DIR:-无}"

    echo -e "${C}--- 话题 ---${N}"
    for t in /cloud_registered /flmap/cloud; do
        printf "  %-20s " "$t"
        PYTHONUNBUFFERED=1 timeout 4 ros2 topic hz "$t" 2>/dev/null | grep -m1 "average rate" || echo "无数据"
    done

    echo -e "${C}--- 硬件 ---${N}"
    echo "  SOC: $(for z in /sys/class/thermal/thermal_zone*/temp; do awk '{printf "%.0f ", $1/1000}' "$z" 2>/dev/null; done)℃"
    echo "  负载: $(uptime | sed 's/.*load average: //')"
    echo "  内存: $(free -h | awk '/^Mem:/{print $3"/"$2}')"
}

do_stats() {
    echo -e "${C}--- bridge 统计（最近 3 行）---${N}"
    grep -E "in .* pts" "$LOG_DIR/bridge.log" 2>/dev/null | tail -3 | sed 's/^/  /' \
        || echo "  还没有统计（默认每 60 帧一行，约 12 秒）"
    echo -e "${C}--- 输出帧率 ---${N}"
    printf "  /flmap/cloud  "
    PYTHONUNBUFFERED=1 timeout 5 ros2 topic hz /flmap/cloud 2>/dev/null | grep -m1 "average rate" || echo "无数据"
}

do_link() {
    # 网口清单与链路类型强相关（有线只看 en*/eth*，无线还要看信号），
    # 所以整段交给 lib_link.sh，本函数只负责测 RTT。
    if declare -F link_report_ifaces >/dev/null 2>&1; then
        link_report_ifaces
    else
        echo -e "${C}--- 网口 ---${N}"
        ip -br addr | sed 's/^/  /'
    fi

    echo -e "${C}--- 到 PC ($PC_IP) ---${N}"
    local pout
    if [ -n "$PC_IP" ] && pout=$(ping -c 20 -i 0.2 -q "$PC_IP" 2>/dev/null); then
        echo "$pout" | tail -2 | sed 's/^/  /'
        echo "  看丢包率为准：Orin 在跑 LIO 时 ping 的 RTT 会被调度放大到 10 ms 级，"
        echo "  链路真值以 PC 端 ./scripts/link_probe.sh 为准"
    else
        echo -e "  ${R}ping 不通${N} —— ${LINK_HINT_PC:-先看网口是否 up、地址是否配好}"
        echo "  期望: 0% packet loss, rtt avg < 2 ms"
    fi

    echo -e "${C}--- 到雷达 (192.168.123.221) ---${N}"
    local lout
    if lout=$(ping -c 5 -i 0.2 -q 192.168.123.221 2>/dev/null); then
        echo "$lout" | tail -2 | sed 's/^/  /'
    else
        echo -e "  ${R}雷达不通${N} —— 雷达没上电 / IP 不是 .221（见 docs/08）"
    fi
}

do_quit() {
    [ "$REC_STATE" != "idle" ] && do_stop
    log "${Y}关闭节点…${N}"
    [ -n "$BRG_PID" ] && kill -INT "$BRG_PID" 2>/dev/null
    [ -n "$MAP_PID" ] && kill -INT "$MAP_PID" 2>/dev/null
    sleep 3
    [ -n "$DRV_PID" ] && kill -INT "$DRV_PID" 2>/dev/null
    sleep 2
    cleanup
    log "${G}已退出${N}"
}

do_help() {
    # 这条说明由链路层给：有线包讲网口速率，无线包讲信号/速率。
    # 本脚本两包同一份，不许在这里写死任何一边的说法。
    local ldesc="链路体检（网口状态 + 到 PC/雷达的 RTT）"
    declare -F link_help_desc >/dev/null 2>&1 && ldesc=$(link_help_desc)
    cat <<EOF
  start   开始新扫描（首次会问是否体检）
  pause   暂停录包       resume 继续录包
  stop    停止录包 + 导出 PCD
  status  进程/话题/硬件
  stats   bridge 输出频率与压缩比
  link    ${ldesc}
  env     手动跑一次环境体检
  quit    退出（自动 stop + 关节点）
EOF
}

# ================= 主流程 =================
# 非交互一次性执行：`edge_control.sh status` 这类调用只跑一条命令就退出，
# 绝不能走 cleanup/start_nodes —— 否则从 PC 上 `ssh ... edge_control.sh status | tail`
# 会因为 stdin 是管道、read 立刻 EOF 而触发 do_quit，把正在跑的建图关掉。
#
# 但判断条件不能是 `$# -gt 0`：`--no-bag` 是启动选项，不是子命令。
# 之前写成"有参数就是一次性命令"，`edge_control.sh --no-bag` 会直接打印
# "只支持 status/stats/link/env" 然后退出 —— 命令看着成功，实际什么都没启动。
case "${1:-}" in
    status)         trap - INT TERM; do_status; exit 0 ;;
    stats)          trap - INT TERM; do_stats;  exit 0 ;;
    link)           trap - INT TERM; do_link;   exit 0 ;;
    env)            trap - INT TERM; bash "$REPO_DIR/scripts/env_check.sh"; exit 0 ;;
    help|-h|--help) trap - INT TERM; do_help;   exit 0 ;;
esac

trap 'do_quit; exit 0' INT TERM
# 先 cleanup 再 start：上一次如果是 Ctrl-C / SSH 掉线 / 直接拔网线退出的，
# 驱动、LIO、bridge 会留在后台，这里一并清掉。否则同一个话题会出现两个发布者
# （两个雷达驱动各自发 /livox/lidar），现象是频率翻倍、点云交替跳变。
cleanup
start_nodes

log ""
log "${C}========================================${N}"
log "${C} 狗端建图控制台（可视化在 PC 端）${N}"
log "${C} 命令: start / stop / status / stats / link / quit${N}"
log "${C}========================================${N}"

# ---- 无人值守模式（--auto N）----
# 交互模式靠人按时序敲 start/stop，脚本要自动化时就只能靠管道喂命令，
# 而喂命令的时序跟节点启动速度强耦合（抢跑会被当成"未知命令"，晚到会被
# ask_env_check 的 read 吃掉），实跑时踩过两次。这里改成自己数秒，
# 彻底不碰 stdin —— 于是可以安全地被 `ssh unitree@… 'edge_control.sh --auto 90'` 调用。
if [ -n "$AUTO_SEC" ]; then
    log "${C}[auto] 无人值守：录 ${AUTO_SEC}s → 自动 stop + 导出 PCD${N}"
    ENV_CHECKED=1          # 跳过体检问答：auto 模式没有键盘
    do_start
    if [ "$REC_STATE" != "recording" ]; then
        log "${R}[auto] 录包没起来，放弃${N}"
        do_quit
        exit 1
    fi
    AUTO_TASK="$TASK_DIR"
    _i=0
    while [ "$_i" -lt "$AUTO_SEC" ]; do
        sleep 1; _i=$((_i + 1))
        [ $((_i % 15)) -eq 0 ] && log "[auto] 已录 ${_i}/${AUTO_SEC}s"
    done
    do_stop
    # do_stop 结束时会清空 TASK_DIR，先留一份给调用方（PC 端要拿它 scp）
    log "TASK_DIR=${AUTO_TASK:-none}"
    do_quit
    exit 0
fi

while true; do
    printf "${G}flmap> ${N}"
    read -r cmd || { do_quit; exit 0; }
    case "$cmd" in
        start)  do_start ;;
        pause)  do_pause ;;
        resume) do_resume ;;
        stop)   do_stop ;;
        status) do_status ;;
        stats)  do_stats ;;
        link)   do_link ;;
        env)    bash "$REPO_DIR/scripts/env_check.sh" ;;
        quit|exit) do_quit; exit 0 ;;
        help|"") do_help ;;
        *) log "${Y}未知命令: $cmd${N}" ;;
    esac
done
