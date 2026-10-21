#!/bin/bash
# =============================================================
#  pc_view.sh —— PC 端一键远程可视化
#
#  做三件事：
#    1. 配好和狗端一致的 DDS 环境（CycloneDDS + DOMAIN 42）
#    2. 快速确认狗端在不在线、点云有没有过来
#    3. 起 flmap_accumulator + RViz2
#
#  用法:
#    ./scripts/pc_view.sh                 # 正常开窗口
#    ./scripts/pc_view.sh --headless      # 不起 RViz（只收数据，用其他工具看）
#    ./scripts/pc_view.sh --raw           # 不攒图，只看狗端发来的当前帧
#    EDGE_HOST=192.168.1.50 ./scripts/pc_view.sh
# =============================================================

set -o pipefail   # 注意：不开 set -u —— ROS 的 setup.bash 会引用未定义变量

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 目标地址与链路判据统一走 lib_link.sh —— 本脚本在无线包/有线包里是同一份，
# 这里不许出现任何具体网段，否则两包就会各自漂移。
# shellcheck source=lib_link.sh
source "$REPO_DIR/scripts/lib_link.sh"
EDGE_HOST=$(link_resolve 5)
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export ROS_DOMAIN_ID RMW_IMPLEMENTATION
export ROS_LOCALHOST_ONLY=0

# 同 edge_control.sh：别把 shell 里继承来的 CYCLONEDDS_URI 带进节点。
# 一份版本不匹配的 xml 会让 rmw_create_node 直接失败，症状是"节点秒退"。
# 但也不能放任它自动挑网卡：机器上往往不止一块网卡，CycloneDDS 会
# "selected arbitrarily" 挑一张，挑中手机 RNDIS 那块就永远收不到点云。
# dds_bind.sh 按到 EDGE_HOST 的路由生成绑定配置，与链路类型无关。
# 注意：这里还没定义 say()，只能用 echo
if [ "${FLMAP_KEEP_CYCLONEDDS:-0}" = "1" ]; then
    echo "[pc_view] 沿用继承来的 CYCLONEDDS_URI=${CYCLONEDDS_URI:-<空>}"
elif DDS_XML=$(bash "$REPO_DIR/scripts/dds_bind.sh" pc 2>/dev/null); then
    export CYCLONEDDS_URI="file://$DDS_XML"
    echo "[pc_view] DDS 绑定: $(sed -n 's:.*<NetworkInterfaceAddress>\(.*\)</NetworkInterfaceAddress>.*:\1:p' "$DDS_XML")"
else
    unset CYCLONEDDS_URI
    echo "[pc_view] 没生成 DDS 绑定配置，回退到自动选网卡"
fi

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[pc_view]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

LAUNCH_ARGS=()
for a in "$@"; do
    case "$a" in
        --headless) LAUNCH_ARGS+=("rviz:=false") ;;
        --raw)      LAUNCH_ARGS+=("accumulate:=false") ;;
        -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
        *)          LAUNCH_ARGS+=("$a") ;;
    esac
done

# ---- 1. ROS 环境 ----
# 系统 python 优先：装了 conda / pyenv 的机器上，PATH 里的 python3 往往没有
# numpy 和 ROS 的 python 绑定，累加器会直接 ModuleNotFoundError 退出。
export PATH="/usr/bin:$PATH"
for d in humble foxy; do
    if [ -f "/opt/ros/$d/setup.bash" ]; then
        # shellcheck disable=SC1090
        source "/opt/ros/$d/setup.bash"
        break
    fi
done
[ -z "${ROS_DISTRO:-}" ] && die "没找到 /opt/ros/{humble,foxy}/setup.bash"

if [ -f "$REPO_DIR/install/setup.bash" ]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/install/setup.bash"
else
    die "本仓库还没编译：先在仓库根目录跑 ./setup.sh"
fi
ok "ROS ${ROS_DISTRO} | DOMAIN ${ROS_DOMAIN_ID} | ${RMW_IMPLEMENTATION}"

# ---- 2. 链路快检 ----
say "检查到狗端 ${EDGE_HOST} 的连通性…"
if ping -c 3 -W 1 "$EDGE_HOST" >/dev/null 2>&1; then
    rtt=$(ping -c 5 -i 0.2 -q "$EDGE_HOST" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
    ok "ping 通，平均 RTT ${rtt:-?} ms"
else
    warn "ping ${EDGE_HOST} 不通。可视化会是一片空白。排查见 docs/02-network-and-dds.md："
    link_ping_hint
    sleep 3
fi

say "等待狗端的 /flmap/cloud（最多 10 秒）…"
# 用 `timeout 8 ros2 topic hz | grep -q` 做存在性判断会偶发误报：新建 DDS participant
# 首次发现端点偶尔要好几秒，超时被杀就当成了"没数据"（实测有过一次明明在发点云却报空）。
# 换成 `echo --once`：收到一条立刻退出，不用等率统计，也不受发现延迟叠加影响。
probe_cloud() {
    local rel="$1"
    timeout 10 ros2 topic echo /flmap/cloud --once --field width \
        --qos-reliability "$rel" 2>/dev/null | head -1
}
W="$(probe_cloud reliable)"
[ -z "$W" ] && W="$(probe_cloud best_effort)"

if [ -n "$W" ]; then
    # 频率统计：ros2 CLI 是 Python，stdout 非 TTY 时按块缓冲，
    # timeout 杀掉进程前 grep 收不到任何字节（实测 stdbuf -oL 也无效，
    # 因为 Python 在 libc 之上还有自己的一层缓冲）。必须 PYTHONUNBUFFERED。
    hz=$(PYTHONUNBUFFERED=1 timeout 6 ros2 topic hz /flmap/cloud 2>/dev/null \
         | grep -m1 "average rate" | awk '{print $3}')
    ok "收到点云，当前帧 ${W} 点，约 ${hz:-?} Hz"
else
    warn "/flmap/cloud 没数据 —— RViz 会空着。常见原因："
    warn "  1) 狗端 bridge 没起来：ssh 上去看 pgrep -af flmap_bridge_node，或跑 scripts/edge_control.sh status"
    warn "  2) 两边 ROS_DOMAIN_ID 不一致（本脚本用 ${ROS_DOMAIN_ID}）"
    warn "  3) 两边 RMW 不一致（本脚本用 ${RMW_IMPLEMENTATION}）"
    warn "  4) 本机网卡选错（多网卡时 CycloneDDS 可能绑错），跑 ./scripts/link_probe.sh 看详情"
fi

# ---- 3. RViz 的 GL 准备 ----
# RViz 必须有可用的 OpenGL 上下文，而硬件 GL 需要设备节点：
#   /dev/dri/renderD128（mesa）  或  /dev/nvidia0（nvidia 专有）
# 两个都不存在时（容器里、显卡驱动没加载、纯 VNC/远程 X），rviz2 会刷屏报
#   Unable to create a suitable GLXContext in GLXContext::GLXContext
#   Failed to create an OpenGL context. BadValue
# 然后窗口永远不出现 —— 而 ROS 侧一切正常（点云在收、累加器在发），
# 很容易被误判成"链路断了"。这时只能让 GLVND 走 mesa 软件光栅。
# 实测：只设 LIBGL_ALWAYS_SOFTWARE=1 不够，必须同时指定 __GLX_VENDOR_LIBRARY_NAME=mesa。
if [ "${FLMAP_SOFT_GL:-auto}" != "0" ] && [ ! -e /dev/dri ] && [ ! -e /dev/nvidia0 ]; then
    warn "没有 GPU 设备节点（/dev/dri、/dev/nvidia0）→ RViz 切软件渲染（能看，帧率低）"
    export LIBGL_ALWAYS_SOFTWARE=1
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    export GALLIUM_DRIVER=llvmpipe
fi

# ---- 4. 启动 ----
say "启动累加器 + RViz…"
exec ros2 launch flmap_bringup pc_view.launch.py "${LAUNCH_ARGS[@]}"
