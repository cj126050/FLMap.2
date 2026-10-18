#!/bin/bash
# =============================================================
#  deploy_edge.sh —— 把仓库同步到 Go2 拓展坞并远程编译
#
#  为什么要单独一个脚本：
#    狗端是 Ubuntu 20.04 + Foxy，PC 端是 Humble，**不能用同一份 src**。
#    本脚本的做法是「PC 保留干净源码，狗端拿一份打过 Foxy 补丁的副本」，
#    这样两边互不污染，PC 端随时可以重新编译验证。
#
#  用法:
#    ./scripts/deploy_edge.sh                # 同步 + 打补丁 + 编译
#    ./scripts/deploy_edge.sh --no-build     # 只同步，不编译
#    ./scripts/deploy_edge.sh --no-patch     # 同步 + 编译，跳过 Foxy 补丁（已打过时）
#
#  环境变量:
#    EDGE_HOST  狗端 IP        默认 192.168.123.18
#    EDGE_USER  狗端用户名      默认 unitree
#    EDGE_WS    狗端工作空间    默认 ~/flmap_ws
#
#  前置条件：已能 ssh 免密登录狗端（ssh-copy-id unitree@192.168.123.18）
# =============================================================

set -uo pipefail

EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
EDGE_WS="${EDGE_WS:-~/flmap_ws}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="ssh -o ConnectTimeout=8 -o BatchMode=yes ${EDGE_USER}@${EDGE_HOST}"

DO_BUILD=1
DO_PATCH=1
for a in "$@"; do
    case "$a" in
        --no-build) DO_BUILD=0 ;;
        --no-patch) DO_PATCH=0 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    esac
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[deploy]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

# ---------------------------------------------------------------- 1. 连通性
say "检查到 ${EDGE_USER}@${EDGE_HOST} 的连接…"
if ! $SSH true 2>/dev/null; then
    die "ssh 不通。先确认：
      - PC 已连上狗（有线 192.168.123.10/24 或 Wi-Fi 同网段）
      - ping ${EDGE_HOST} 通
      - 已 ssh-copy-id ${EDGE_USER}@${EDGE_HOST}"
fi
ok "ssh 可用"

REMOTE_ROS=$($SSH 'if [ -f /opt/ros/foxy/setup.bash ]; then echo foxy; elif [ -f /opt/ros/humble/setup.bash ]; then echo humble; else echo none; fi')
[ "$REMOTE_ROS" = "none" ] && die "狗端没有装 ROS 2（/opt/ros/{foxy,humble} 都不存在）"
say "狗端 ROS 发行版: ${REMOTE_ROS}"

# ---------------------------------------------------------------- 2. 同步
say "同步源码 → ${EDGE_WS}"
$SSH "mkdir -p ${EDGE_WS}" || die "无法创建远端目录"

# 只同步源码与脚本；不传 build/install/log，也不传 .git（体积大且无用）
rsync -a --delete-delay \
    --exclude 'build/' --exclude 'install/' --exclude 'log/' \
    --exclude '.git/' --exclude '__pycache__/' --exclude '*.pyc' \
    --exclude '.vscode/' --exclude 'bags/' \
    "$REPO_DIR"/ "${EDGE_USER}@${EDGE_HOST}:${EDGE_WS}/" \
    || die "rsync 失败"
ok "同步完成"

# ---------------------------------------------------------------- 3. Foxy 补丁
if [ "$DO_PATCH" = "1" ] && [ "$REMOTE_ROS" = "foxy" ]; then
    say "应用 Foxy 兼容补丁…"
    $SSH "cd ${EDGE_WS} && bash scripts/patch_foxy.sh ${EDGE_WS}" 2>&1 | sed 's/^/    /'
    ok "补丁完成（幂等，可重复执行）"
fi

# ---------------------------------------------------------------- 4. 编译
if [ "$DO_BUILD" = "1" ]; then
    say "狗端编译（Orin Nano 上约 4-8 分钟）…"
    $SSH "cd ${EDGE_WS} && \
        source /opt/ros/${REMOTE_ROS}/setup.bash && \
        export PATH=/usr/bin:\$PATH && \
        colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release" 2>&1 | tail -20 | sed 's/^/    /'
    # 用 tee 拿不到远端退出码，单独验证产物
    if $SSH "test -f ${EDGE_WS}/install/setup.bash"; then
        ok "编译产物就绪: ${EDGE_WS}/install/setup.bash"
    else
        die "编译未产出 install/setup.bash，看上面的报错"
    fi
fi

echo
say "下一步（在狗端终端里）:"
echo "    ssh ${EDGE_USER}@${EDGE_HOST}"
echo "    cd ${EDGE_WS} && ./scripts/edge_control.sh"
echo
say "PC 端可视化:"
echo "    ./scripts/pc_view.sh"
