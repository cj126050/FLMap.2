#!/usr/bin/env bash
# =============================================================
#  wifi_offline_probe.sh —— 离线版链路体检，结论写进日志文件
#
#  为什么需要离线版
#  ----------------
#  PC 一旦把 Wi-Fi 切到 Go2 自己的热点，就同时丢掉了公网出口
#  （本机默认路由是 via <家里路由器> dev wlan0）。也就是说：切过去的那一刻，
#  远程协助就断了，没法一边测一边有人给你读结果。
#
#  所以这个脚本把全部判断都做完、写进一个文本文件，你切回原来的 Wi-Fi 后
#  把文件内容交给 AI 读即可。它不需要联网，也不需要人在旁边。
#
#  用法
#    ./scripts/wifi_offline_probe.sh
#    ./scripts/wifi_offline_probe.sh 192.168.123.18
#
#  它会输出日志路径，形如 logs/wifi_probe_20261018_2140.log
#  只读操作，不改任何网络配置（需要你改的地方会打印出来，由你自己执行）。
# =============================================================
set -uo pipefail

EDGE_HOST="${1:-${EDGE_HOST:-192.168.123.18}}"
EDGE_USER="${EDGE_USER:-unitree}"
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${HOME}/.ssh/known_hosts")

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO_DIR/logs"
LOG="$REPO_DIR/logs/wifi_probe_$(date +%Y%m%d_%H%M%S).log"

# 所有输出同时进日志和屏幕
exec > >(tee "$LOG") 2>&1

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
sec() { printf '\n%s── %s %s\n' "$c_b" "$1" "$c_0"; }
ok()  { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
info(){ printf '    %s\n' "$1"; }

echo "============================================================"
echo " 无线链路离线体检    $(date '+%F %T')"
echo " 目标拓展坞 ${EDGE_HOST}   日志 $LOG"
echo "============================================================"

# ---------------------------------------------------------------- 0. 环境快照
sec "0. 环境快照"
info "主机名 $(hostname)   内核 $(uname -r)"
echo "  接口地址:"
ip -o -4 addr show 2>/dev/null | awk '{printf "    %-10s %s\n", $2, $4}'
echo "  默认路由:"
ip route show default 2>/dev/null | sed 's/^/    /' | head -3
[ -z "$(ip route show default 2>/dev/null)" ] && warn "没有默认路由"

# ---------------------------------------------------------------- 1. 走哪条路
sec "1. 到 ${EDGE_HOST} 实际走哪块网卡"
ROUTE_LINE=$(ip route get "$EDGE_HOST" 2>/dev/null | head -1)
if [ -z "$ROUTE_LINE" ]; then
    bad "无路由（既不在同网段，也没有默认路由可用）"
    OUT_IFACE=""; SRC_IP=""
else
    OUT_IFACE=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    SRC_IP=$(printf '%s\n' "$ROUTE_LINE"   | sed -n 's/.* src \([^ ]*\).*/\1/p')
    VIA=$(printf '%s\n' "$ROUTE_LINE"      | sed -n 's/.* via \([^ ]*\).*/\1/p')
    info "出口 ${OUT_IFACE:-?}   源地址 ${SRC_IP:-?}   ${VIA:+经网关 $VIA}"
fi

IS_WIFI=0
if [ -n "$OUT_IFACE" ] && { [ -e "/sys/class/net/${OUT_IFACE}/wireless" ] || [ -e "/sys/class/net/${OUT_IFACE}/phy80211" ]; }; then
    IS_WIFI=1
    ok "${OUT_IFACE} 是无线接口 —— 说明包确实走了 Wi-Fi"
elif [ -n "$OUT_IFACE" ]; then
    case "$OUT_IFACE" in
        eth*|en*)
            if [ "$(cat "/sys/class/net/${OUT_IFACE}/operstate" 2>/dev/null)" != "up" ]; then
                bad "${OUT_IFACE} 是有线，但链路已 down —— 这是黑洞，包发出去没人接"
                warn "有线网卡上还留着 192.168.123.x 的地址，它的直连路由比默认路由更精确，"
                warn "所以去往 ${EDGE_HOST} 的包全被它抢走。必须先把这个地址摘掉："
                info "sudo ip addr del 192.168.123.10/24 dev ${OUT_IFACE}"
                info "# 或整块网卡关掉（拔线后可执行）："
                info "sudo ip link set ${OUT_IFACE} down"
            else
                warn "${OUT_IFACE} 是有线且链路 up —— 网线还插着，这次测的不是无线"
                warn "要测无线，请把网线从 PC 上拔掉再跑本脚本"
            fi ;;
        *) warn "${OUT_IFACE} 类型未识别" ;;
    esac
fi

# ---------------------------------------------------------------- 2. 无线参数
sec "2. 无线链路参数"
if [ "$IS_WIFI" = "1" ]; then
    SSID=$(iw dev "$OUT_IFACE" info 2>/dev/null | sed -n 's/^[[:space:]]*ssid //p')
    info "SSID: ${SSID:-读不到}"
    iw dev "$OUT_IFACE" link 2>/dev/null | sed -n \
        -e 's/^[[:space:]]*freq:[[:space:]]*/    频率: /p' \
        -e 's/^[[:space:]]*signal:[[:space:]]*/    信号: /p' \
        -e 's/.*bitrate:[[:space:]]*/    速率: /p' \
        -e 's/^[[:space:]]*tx failed:[[:space:]]*/    发送失败: /p'
    BAND=$(iw dev "$OUT_IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*freq:[[:space:]]*\([0-9]*\).*/\1/p')
    if [ -n "$BAND" ]; then
        if [ "$BAND" -lt 3000 ] 2>/dev/null; then
            warn "工作在 2.4 GHz（${BAND} MHz）—— 与遥控图传同频段，抖动会明显"
        else
            ok "工作在 5 GHz（${BAND} MHz）"
        fi
    fi
else
    info "当前不走无线，跳过"
fi

# ---------------------------------------------------------------- 3. 公网
sec "3. 公网是否还在（预期：已断）"
if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
    ok "公网仍可达（说明 PC 还有其他出口，比如手机 USB 共享网络）"
    NET_OK=1
else
    warn "公网不可达 —— 符合预期。这就是为什么要用离线脚本"
    NET_OK=0
fi

# ---------------------------------------------------------------- 4. 去程
sec "4. 去程（PC → 狗）"
PING_OUT=$(ping -c 10 -i 0.2 -W 1 "$EDGE_HOST" 2>&1)
LOSS=$(printf '%s\n' "$PING_OUT" | sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p' | tail -1)
RTT=$(printf '%s\n' "$PING_OUT"  | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^ ]*\).*/\1/p')
if [ "${LOSS:-100}" = "100" ] || [ -z "$RTT" ]; then
    bad "去程不通（丢包 ${LOSS:-100}%）"
    printf '%s\n' "$PING_OUT" | sed 's/^/    /' | head -6
    GO_OK=0
else
    ok "去程通：丢包 ${LOSS}%，RTT min/avg/max/mdev = ${RTT}"
    GO_OK=1
fi

# ---------------------------------------------------------------- 5. 回程
sec "5. 回程（狗 → PC）  ← C 方案最容易死在这里"
BACK_OK=0
if [ "$GO_OK" = "1" ] && [ -n "${SRC_IP:-}" ]; then
    BACK_OUT=$(ssh "${SSH_OPTS[@]}" "${EDGE_USER}@${EDGE_HOST}" \
               "ping -c 3 -W 1 ${SRC_IP} 2>&1 | tail -3" 2>/dev/null)
    printf '%s\n' "$BACK_OUT" | sed 's/^/    /'
    if printf '%s\n' "$BACK_OUT" | grep -qE '[1-3] (packets )?received'; then
        ok "回程通：狗能 ping 回 PC 的 ${SRC_IP}"
        BACK_OK=1
    else
        bad "回程不通：狗 ping 不回 PC 的 ${SRC_IP}"
        info "这等价于：ping 有回应但 ros2 topic list 永远空。"
        info "原因通常是狗端只有一条指向 192.168.123.1 的默认路由，"
        info "而该网关是幽灵（ARP 不完整），回程包全掉进黑洞。"
        info "修法（在狗上执行，需要 sudo）："
        info "sudo ip route add ${SRC_IP}/32 via <PC 在热点网段的网关>"
    fi
else
    warn "去程不通或无源地址，回程测试跳过"
fi

# ---------------------------------------------------------------- 6. 狗端视角
sec "6. 狗端网络视角"
ssh "${SSH_OPTS[@]}" "${EDGE_USER}@${EDGE_HOST}" '
    echo "    --- 地址 ---"; ip -o -4 addr show | awk "{printf \"      %-8s %s\n\", \$2, \$4}"
    echo "    --- 默认路由 ---"; ip route show default | sed "s/^/      /"
    echo "    --- 运控可达? ---"
    ping -c 2 -W 1 192.168.123.161 >/dev/null 2>&1 && echo "      运控 161 可达" || echo "      运控 161 不可达"
    echo "    --- 幽灵网关检查 ---"
    GW=$(ip route show default | sed -n "s/.*via \([^ ]*\).*/\1/p" | head -1)
    if [ -n "$GW" ]; then
        if ping -c 1 -W 1 "$GW" >/dev/null 2>&1; then
            echo "      默认网关 $GW 可达"
        else
            echo "      默认网关 $GW 不可达（幽灵路由，回程包会掉进这里）"
        fi
    fi
' 2>/dev/null | sed 's/^/  /' || warn "ssh 连不上狗端，无法读取狗端视角"

# ---------------------------------------------------------------- 7. DDS 粗测
sec "7. DDS 端口粗测（狗端 7400 起）"
if [ "$GO_OK" = "1" ]; then
    if timeout 3 bash -c "echo > /dev/tcp/${EDGE_HOST}/7400" 2>/dev/null; then
        warn "7400 端口可连 —— 但端口能连不代表 DDS 能发现，最终还要看 ros2 topic list"
    else
        info "7400 端口未监听（正常：CycloneDDS 只在有节点运行时才占用）"
    fi
fi

# ---------------------------------------------------------------- 结论
sec "结论"
if [ -n "$OUT_IFACE" ] && [ "$IS_WIFI" = "0" ] && [ "$GO_OK" = "1" ]; then
    printf '  %s这次测的仍然是有线链路，结论对无线无效。%s\n' "$c_y" "$c_0"
    printf '  请拔掉网线（并摘掉有线网卡上的 192.168.123.x 地址）后重跑。\n'
elif [ "$GO_OK" = "1" ] && [ "$BACK_OK" = "1" ]; then
    printf '  %s双向无线链路可用，方案 C（借 Go2 自带 Wi-Fi）成立。%s\n' "$c_g" "$c_0"
    printf '  下一步：按 docs/09 改单播 DDS 配置，再跑建图。\n'
elif [ "$GO_OK" = "1" ] && [ "$BACK_OK" = "0" ]; then
    printf '  %s去程通、回程不通。%s这是纯转发型拓扑的典型表现，狗端缺回程路由。\n' "$c_r" "$c_0"
    printf '  要么在狗上加一条路由（需 sudo），要么改用 A 方案（USB 网卡，同网段免路由）。\n'
elif [ "$GO_OK" = "1" ]; then
    printf '  %s去程通，但走的是有线。%s拔网线重测才能判断无线。\n' "$c_y" "$c_0"
else
    printf '  %s链路不通。%s先看第 1 节标红的那条。\n' "$c_r" "$c_0"
fi

echo
echo "============================================================"
echo " 日志已保存： $LOG"
echo " 现在把 Wi-Fi 切回原来的网络，让 AI 读这个文件即可。"
echo "============================================================"
