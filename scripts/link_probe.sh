#!/bin/bash
# =============================================================
#  link_probe.sh —— 链路体检（在 PC 上跑）
#
#  这个脚本回答一个问题：**PC 到底能不能稳定收到狗端的点云？**
#  它按"物理/网络层 → 连通性 → SSH → DDS 层 → 应用层"依次测，
#  哪一层先红，问题就在哪一层。对应排查步骤见 docs/02-network-and-dds.md。
#
#  ★ 本文件在 FLMap.2（无线包）和 FLMap.3（有线包）里是**同一份**。
#    链路差异全部收在 scripts/lib_link.sh：目标地址、期望网卡、信号/速率判据、
#    失败提示都由它提供。所以改体检逻辑不会让两包行为分叉，
#    改链路判据也只需要动那一个文件。
#
#  用法:
#    ./scripts/link_probe.sh
#    EDGE_HOST=192.168.123.161 ./scripts/link_probe.sh     # 测运控
#    ./scripts/link_probe.sh --bw                          # 附带 iperf3 带宽测试
# =============================================================

set -o pipefail   # 注意：不开 set -u —— ROS 的 setup.bash 会引用未定义变量

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib_link.sh
source "$REPO_DIR/scripts/lib_link.sh"

EDGE_HOST=$(link_resolve 10)
EDGE_USER="${EDGE_USER:-unitree}"
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
export ROS_DOMAIN_ID
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"

WITH_BW=0
[ "${1:-}" = "--bw" ] && WITH_BW=1

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
VERDICT=()

say()  { echo -e "\n${B}${C}== $* ==${N}"; }
pass() { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; VERDICT+=("$*"); }
fail() { echo -e "  ${R}✘${N} $*"; VERDICT+=("$*"); }

# ---- ROS 环境（只为跑 ros2 CLI）----
for d in humble foxy; do
    [ -f "/opt/ros/$d/setup.bash" ] && { source "/opt/ros/$d/setup.bash"; break; }
done
[ -f "$REPO_DIR/install/setup.bash" ] && source "$REPO_DIR/install/setup.bash"

echo -e "${B}链路体检${N}  ${LINK_KIND} · 目标 ${EDGE_HOST}  DOMAIN ${ROS_DOMAIN_ID}  RMW ${RMW_IMPLEMENTATION}"
echo "  链路: ${LINK_DESC}"

# ---------------------------------------------------------------- 1. 物理/网络
say "1. 本机网络"
ip -br addr show 2>/dev/null | awk '$1!="lo"{printf "  %-12s %-8s %s\n", $1, $2, $3}'

# 本机地址是后面所有测试的前提：缺了它，每条都会失败，而且报错会指向
# "狗没开机""雷达坏了"，全是假线索。先把这个前提单独说清楚。
link_check_local
LOCAL_OK=$?

ROUTE_IF=$(ip route get "$EDGE_HOST" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -n "$ROUTE_IF" ] && echo "  到 ${EDGE_HOST} 走: ${ROUTE_IF}"
link_check_iface "$ROUTE_IF"
# 这里必须留住返回码。以前只打印不判断，于是"从有线口/默认网关绕出去 ping 通"
# 会被当成链路正常 —— 目标地址在别的网段上由无关设备应答，0% 丢包完全是假绿灯。
IFACE_OK=$?

# ---------------------------------------------------------------- 2. 连通性
say "2. 连通性与时延（20 包）"
PING=$(ping -c 20 -i 0.2 -W 1 "$EDGE_HOST" 2>/dev/null)
if echo "$PING" | grep -q "0% packet loss\|[1-9][0-9]* received"; then
    LOSS=$(echo "$PING" | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')
    # ping -q 的统计行：rtt min/avg/max/mdev = a/b/c/d ms
    # 用 '/' 切之后 $4="mdev = a"、$5=b(avg)、$6=c(max)、$7="d ms"
    LINE=$(echo "$PING" | grep -E 'rtt|round-trip' | tail -1)
    MIN=$(echo "$LINE" | awk -F'/' '{n=split($4,a," "); print a[n]}')
    AVG=$(echo "$LINE" | awk -F'/' '{print $5}')
    MAX=$(echo "$LINE" | awk -F'/' '{print $6}')
    MDEV=$(echo "$LINE" | awk -F'/' '{print $7}' | awk '{print $1}')
    echo "  丢包 ${LOSS:-?}%  RTT min/avg/max = ${MIN:-?}/${AVG:-?}/${MAX:-?} ms  抖动 ${MDEV:-?} ms"
    # 三层"数字不可信"要分开说，否则用户看到 0% 丢包就以为链路是通的：
    #   1) 回包从错误的网口绕出去的（最容易误判，实际是别的设备在应答）
    #   2) 本机压根没配链路网段的地址
    PING_INVALID=0
    if [ "$IFACE_OK" != "0" ]; then
        fail "这组数字不作数：回包不是 ${EDGE_HOST}，是从 ${ROUTE_IF:-未知出口} 绕出去被别的设备应答的"
        echo "     目标地址在其它网段上也可能存在同名主机（本机默认路由会把它当普通外网地址转发）"
        echo "     别据此认为狗在线；先按 §1 修地址/路由，再重跑本脚本"
        PING_INVALID=1
    elif [ "$LOCAL_OK" != "0" ]; then
        fail "本机没有 ${LINK_LOCAL_PREFIX}x 地址，这组数字不可信 —— 先按 §1 配好地址再测"
    else
        awk -v l="${LOSS:-0}" 'BEGIN{exit !(l>2)}' \
            && fail "丢包 ${LOSS}% > 2% —— 查物理层：${LINK_DESC}" || pass "丢包正常"
    fi
    read -r AMAX JMAX <<< "$(link_latency_limits)"
    # ping 全丢时统计行里是 "?/?/?"，这时候再说"时延正常"是假绿灯，直接跳过。
    # 回包来源不对时同样跳过 —— 量的是另一个设备的 RTT，判它没有意义。
    if [ "${PING_INVALID:-0}" != "1" ] && [ -n "$AVG" ] && [ -n "$MDEV" ]; then
        awk -v a="$AVG" -v t="$AMAX" 'BEGIN{exit !(a>t)}' \
            && fail "平均 RTT ${AVG} ms > ${AMAX} ms —— 不正常，查本机负载 / 物理层" \
            || pass "时延正常"
        awk -v m="$MDEV" -v t="$JMAX" 'BEGIN{exit !(m>t)}' \
            && warn "抖动 ${MDEV} ms 偏大 —— 点云会一顿一顿" || pass "抖动正常"
    fi
else
    fail "ping 不通 —— 先解决这一层，后面的检查都没意义"
    link_check_hints
    exit 1
fi

# ---------------------------------------------------------------- 3. SSH
say "3. SSH（用于部署/诊断）"
if timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${EDGE_USER}@${EDGE_HOST}" true 2>/dev/null; then
    pass "免密 ssh 可用"
    EDGE_CLOCK=$(timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${EDGE_USER}@${EDGE_HOST}" 'date +%s' 2>/dev/null)
    if [ -n "$EDGE_CLOCK" ]; then
        SKEW=$(( $(date +%s) - EDGE_CLOCK ))
        SKEW=${SKEW#-}
        if [ "$SKEW" -le 1 ]; then
            pass "两端时间差 ≤ ${SKEW}s"
        else
            warn "两端时间差 ${SKEW}s —— 建图前先跑 ./scripts/clock_sync.sh start && check"
        fi
    fi
else
    warn "免密 ssh 不可用 —— deploy_edge.sh 会失败；执行 ssh-copy-id ${EDGE_USER}@${EDGE_HOST}"
fi

# ---------------------------------------------------------------- 4. DDS
say "4. DDS 发现（PC 能否看到狗端节点）"
# 这一节只证明一件事：DDS 图通了（PC 看得到狗端节点）。
# 以前这里自造一个 String 话题跨机 pub/echo，实测不可靠：点云 9.5 Hz 正常、
# 节点也发现得到，自造话题却两个方向都报 0（狗端 echo 起得比 pub 晚、ssh 后台
# 进程的时序都不稳）。会误报的探针比没有更糟，所以删掉。
#
# 数据层交给第 5 节：/flmap/cloud 有没有 10 Hz，那才是真正的主数据流。
NODES=$(timeout 12 ros2 node list 2>/dev/null)
if echo "$NODES" | grep -q "flmap_bridge"; then
    pass "发现狗端 flmap_bridge 节点 —— DDS 发现层双向可达"
elif [ -n "$NODES" ]; then
    warn "看到 $(echo "$NODES" | grep -c .) 个本机节点，但没有狗端节点 —— 狗端建图可能没 start"
else
    fail "一个节点都没发现 —— DDS 没通"
    echo "     1) 两端 RMW 是否一致：PC=${RMW_IMPLEMENTATION}，狗端 .bashrc 里是什么"
    echo "     2) 网卡绑定：bash scripts/dds_bind.sh pc 生成配置，再 export CYCLONEDDS_URI"
fi

# 无论发现成不成功，把多播出口报出来 —— 这里错了的表现是"单向不通"，很难自己想得到
DD_IF=$(ip route get 239.255.0.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
link_check_multicast "$DD_IF" "$ROUTE_IF"

# ---------------------------------------------------------------- 5. 应用层
say "5. 点云流（应用层，最能说明问题）"
RATE=$(PYTHONUNBUFFERED=1 timeout 8 ros2 topic hz /flmap/cloud 2>/dev/null | grep -m1 "average rate" | awk '{print $3}')
if [ -n "$RATE" ]; then
    echo "  /flmap/cloud ≈ ${RATE} Hz"
    # 桥接默认目标 10 Hz（max_rate_hz: 10.0）
    awk -v r="$RATE" 'BEGIN{exit !(r<8.0)}' \
        && warn "帧率 ${RATE} Hz 低于目标 10 Hz —— 看狗端 stats 确认是不是限流/丢帧" \
        || pass "帧率达标"
else
    fail "/flmap/cloud 无数据 —— 狗端建图或桥接没起来（scripts/edge_control.sh status）"
fi

BW=$(timeout 8 ros2 topic bw /flmap/cloud 2>/dev/null | grep -m1 -oE "[0-9.]+ [kMG]B/s" | head -1)
[ -n "$BW" ] && link_bandwidth_note "$BW"

# 有数据但形状可疑 —— 这是"分量串位"的典型场景，必须单独提示
if [ -n "$RATE" ] && [ -f "$REPO_DIR/tools/diag/cloud_stat.py" ]; then
    echo "  想确认点云内容是否正常： python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1"
fi

# ---------------------------------------------------------------- 6. 带宽（可选）
if [ "$WITH_BW" = "1" ]; then
    say "6. 原始带宽（iperf3，需两端都装）"
    if command -v iperf3 >/dev/null && timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=4 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${EDGE_USER}@${EDGE_HOST}" 'command -v iperf3' >/dev/null 2>&1; then
        echo "  在狗端起 iperf3 server 并测 5 秒…"
        timeout 6 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${EDGE_USER}@${EDGE_HOST}" 'pkill -f "iperf3 -s" 2>/dev/null; nohup iperf3 -s -D >/dev/null 2>&1' || true
        sleep 1
        iperf3 -c "$EDGE_HOST" -t 5 -f m 2>/dev/null | awk '/receiver/{print "  下行 "$5, $6}'
    else
        warn "缺少 iperf3（两端都要装：sudo apt install iperf3）"
    fi
fi

# ---------------------------------------------------------------- 结论
echo -e "\n${B}== 结论 ==${N}"
if [ ${#VERDICT[@]} -eq 0 ]; then
    echo -e "  ${G}链路健康，直接 ./scripts/pc_view.sh${N}"
else
    for v in "${VERDICT[@]}"; do echo -e "  ${Y}•${N} $v"; done
    echo -e "\n  对应处置见 docs/02-network-and-dds.md 的「症状 → 处置」表"
fi
