#!/usr/bin/env bash
# =============================================================
#  wifi_path_check.sh —— 判断「PC 到拓展坞」这一跳是有线还是无线，
#                        以及这条路径是否双向可用
#
#  为什么需要它
#  ------------
#  ping 通了不代表能用。点云流是双向的：狗发点云给 PC，PC 的回执/发现包
#  也要回到狗。很多无线拓扑（尤其是中间隔了一台设备做转发的）会出现
#  「去程通、回程不通」——PC 侧 ping 有回应，但狗端的回复包走了默认路由
#  掉进黑洞，表现为 ros2 topic list 永远空。
#
#  这个脚本在第 4 步专门测回程：从狗反向 ping 回 PC。
#
#  用法
#    ./scripts/wifi_path_check.sh                 # 默认 192.168.123.18
#    EDGE_HOST=192.168.1.50 ./scripts/wifi_path_check.sh
#
#  只做只读操作，不改任何网络配置。
# =============================================================
set -uo pipefail

EDGE_HOST="${EDGE_HOST:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${HOME}/.ssh/known_hosts")

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
sec() { printf '\n%s── %s %s\n' "$c_b" "$1" "$c_0"; }
ok()  { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }

# ---------------------------------------------------------------- 1. 路由
sec "1. 到 ${EDGE_HOST} 走哪条路"

ROUTE_LINE=$(ip route get "$EDGE_HOST" 2>/dev/null | head -1)
if [ -z "$ROUTE_LINE" ]; then
    bad "没有到 ${EDGE_HOST} 的路由（不在同一网段，也没有默认路由能用）"
    exit 1
fi
IFACE=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
SRC_IP=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* src \([^ ]*\).*/\1/p')
VIA=$(printf '%s\n' "$ROUTE_LINE" | sed -n 's/.* via \([^ ]*\).*/\1/p')
printf '  网卡 %s   源地址 %s   %s\n' "${IFACE:-?}" "${SRC_IP:-?}" "${VIA:+经网关 $VIA}"

if [ -z "$IFACE" ]; then
    bad "解析不出出口网卡，路由表异常"
    exit 1
fi

# ---------------------------------------------------------------- 2. 链路类型
sec "2. 这条链路是有线还是无线"

LINK_TYPE="unknown"
if [ -e "/sys/class/net/${IFACE}/wireless" ] || [ -e "/sys/class/net/${IFACE}/phy80211" ]; then
    LINK_TYPE="wifi"
    ok "${IFACE} 是无线接口"
    SSID=$(iw dev "$IFACE" info 2>/dev/null | sed -n 's/^[[:space:]]*ssid //p')
    [ -n "$SSID" ] && printf '    当前 SSID: %s\n' "$SSID"
    BITRATE=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/.*bitrate: \([0-9.]*\).*/\1/p')
    [ -n "$BITRATE" ] && printf '    协商速率: %s MBit/s\n' "$BITRATE"
else
    case "$IFACE" in
        eth*|en*) LINK_TYPE="wired"; ok "${IFACE} 是有线接口" ;;
        *) warn "${IFACE} 类型未识别" ;;
    esac
fi

# ---------------------------------------------------------------- 3. 去程
sec "3. 去程（PC → 狗）"

PING_OUT=$(ping -c 5 -i 0.2 -W 1 "$EDGE_HOST" 2>&1)
LOSS=$(printf '%s\n' "$PING_OUT" | sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p' | tail -1)
RTT=$(printf '%s\n' "$PING_OUT" | sed -n 's/.*rtt min\/avg\/max\/mdev = \([^ ]*\).*/\1/p')

if [ "${LOSS:-100}" = "100" ] || [ -z "$RTT" ]; then
    bad "去程不通（丢包 ${LOSS:-100}%）"
    GO_OK=0
else
    ok "去程通，平均 RTT ${RTT##*/}（min/avg/max/mdev = ${RTT}）"
    GO_OK=1
fi

# ---------------------------------------------------------------- 4. 回程
sec "4. 回程（狗 → PC）  ← 最容易被忽略的一步"

BACK_OK=0
if [ "$GO_OK" = "1" ]; then
    if [ -z "$SRC_IP" ]; then
        warn "拿不到 PC 的源地址，跳过回程测试"
    else
        BACK_OUT=$(ssh "${SSH_OPTS[@]}" "${EDGE_USER}@${EDGE_HOST}" \
                   "ping -c 3 -W 1 ${SRC_IP} 2>&1 | tail -2" 2>/dev/null)
        if printf '%s\n' "$BACK_OUT" | grep -qE '[1-3] (packets )?received|[1-3] received'; then
            ok "回程通：狗能 ping 回 PC 的 ${SRC_IP}"
            BACK_OK=1
        else
            bad "回程不通：狗 ping 不到 PC 的 ${SRC_IP}"
            printf '    狗端输出: %s\n' "$(printf '%s\n' "$BACK_OUT" | tr '\n' ' ')"
            printf '    → 狗端缺一条回程路由。典型修法（需在狗上执行，要 sudo）：\n'
            printf '      sudo ip route add %s/32 via <PC 侧网关>\n' "$SRC_IP"
        fi
        # 顺带看狗的默认网关是否活着 —— 死网关会让回程包掉进黑洞
        GW=$(ssh "${SSH_OPTS[@]}" "${EDGE_USER}@${EDGE_HOST}" \
             "ip route show default | head -1" 2>/dev/null)
        if [ -n "$GW" ]; then
            GWA=$(printf '%s\n' "$GW" | sed -n 's/.*via \([^ ]*\).*/\1/p')
            if [ -n "$GWA" ]; then
                if ssh "${SSH_OPTS[@]}" "${EDGE_USER}@${EDGE_HOST}" \
                     "ping -c 1 -W 1 ${GWA} >/dev/null 2>&1"; then
                    ok "狗的默认网关 ${GWA} 可达"
                else
                    warn "狗的默认网关 ${GWA} 不可达（幽灵路由）——非本网段的回程包会掉进这里"
                fi
            fi
        fi
    fi
else
    warn "去程不通，回程测试无意义"
fi

# ---------------------------------------------------------------- 5. 抖动
sec "5. 链路质量（对 5 Hz 点云流最关键的是抖动，不是带宽）"

if [ "$GO_OK" = "1" ] && [ -n "$RTT" ]; then
    MDEV=$(printf '%s\n' "$RTT" | awk -F/ '{print $4}')
    AVG=$(printf '%s\n' "$RTT" | awk -F/ '{print $2}')
    printf '  平均 %s ms，抖动(mdev) %s ms\n' "$AVG" "$MDEV"
    if awk -v a="$AVG" -v m="$MDEV" 'BEGIN{exit !(m>15)}'; then
        bad "抖动过大：点云会一顿一顿。先关省电、固定信道再试"
    elif awk -v a="$AVG" 'BEGIN{exit !(a>30)}'; then
        warn "延迟偏高（>30 ms），可用但手感差"
    else
        ok "延迟与抖动都在舒适区"
    fi
fi

# ---------------------------------------------------------------- 结论
sec "结论"
if [ "$LINK_TYPE" = "wired" ]; then
    printf '  当前走的是%s有线%s链路。点云链路会稳定，但狗被线拴着，无法移动建图。\n' "$c_y" "$c_0"
    printf '  要脱离线缆，需要先给狗端增加无线射频（见 docs/09-wireless-link.md）。\n'
elif [ "$GO_OK" = "1" ] && [ "$BACK_OK" = "1" ]; then
    printf '  %s双向无线链路可用。%s可以按无线模式跑建图。\n' "$c_g" "$c_0"
    printf '  Wi-Fi 上多播发现常常失效，建议改用单播配置：\n'
    printf '    config/cyclonedds_unicast.xml.example（两边 Peer 互指）\n'
else
    printf '  %s无线链路尚不可用。%s按上面标红的那一步处理。\n' "$c_r" "$c_0"
fi
echo
