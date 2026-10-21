#!/usr/bin/env bash
# =============================================================
#  wifi_link_check.sh —— 无线链路体检（PC 走狗的热点，能不能摸到狗）
#
#  背景
#  ----
#  Go2 自带 AP 打开后，PC 连上去会拿到 192.168.12.x。但狗的业务网段是
#  192.168.123.0/24（运控 .161 / 拓展坞 .18 / Mid360 .221），两者之间隔着
#  运控那一跳。能不能通，取决于三件事，本脚本逐条验：
#    1. PC 有没有到 192.168.123.0/24 的路由（没有就永远不通，跟狗无关）
#    2. 运控转不转发（ip_forward / FORWARD 链 / NAT）
#    3. 回程能不能回来（狗端认不认识 192.168.12.0/24）
#
#  为什么不能只 ping 就下结论
#  --------------------------
#  PC 的默认路由通常在另一块网卡上（手机 USB 共享 / 家里 Wi-Fi）。
#  没有 123 段路由时，包被丢给那个默认网关，表现是"ping 不通"，
#  但其实根本没从无线口出去。所以本脚本先补临时路由，再分段判定。
#
#  用法（必须 root，改路由/关省电都要）
#  ----
#    sudo ./scripts/wifi_link_check.sh              # 体检 + 临时补路由 + 判定
#    sudo ./scripts/wifi_link_check.sh --keep-route # 测完保留路由（要跑 DDS 时用）
#    sudo ./scripts/wifi_link_check.sh --no-add     # 只读，不动路由
#    sudo ./scripts/wifi_link_check.sh --clean      # 删掉临时路由
#    sudo ./scripts/wifi_link_check.sh --iface=wlan0
#
#  只加临时路由，不写任何 NetworkManager 配置；重连/重启即失效。
# =============================================================
set -uo pipefail

DOG_NET="192.168.123.0/24"
CTRL="192.168.123.161"     # 运控（有线口）
EDGE="192.168.123.18"      # 拓展坞 Orin Nano
LIDAR="192.168.123.221"    # Mid360
FWD_TARGET="${FWD_TARGET:-192.168.123.254}"   # 几乎肯定不存在的地址，用来判转发
EDGE_USER="${EDGE_USER:-unitree}"

ADD=1; CLEAN=0; KEEP_ROUTE=0; KEEP_PS=0; IFACE="${WIFI_IFACE:-}"
for a in "$@"; do
    case "$a" in
        --no-add)     ADD=0 ;;
        --clean)      CLEAN=1 ;;
        --keep-route) KEEP_ROUTE=1 ;;
        --keep-ps)    KEEP_PS=1 ;;
        --iface=*)    IFACE="${a#*=}" ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
sec()  { printf '\n%s── %s%s\n' "$c_b" "$1" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim()  { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }

printf '%s\n' "============================================================"
printf ' 无线链路体检   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ------------------------------------------------ 0. 权限
if [ "$(id -u)" -ne 0 ]; then
    bad "需要 root：改路由、关省电都要权限"
    dim "sudo $0 $*"
    exit 1
fi

# sudo 下 HOME=/root，ssh 会去找 /root/.ssh 而连不上。按 SUDO_USER 反查真实 home。
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -n "${REAL_HOME:-}" ] || REAL_HOME="$HOME"
SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
         -o "UserKnownHostsFile=$REAL_HOME/.ssh/known_hosts")
[ -f "$REAL_HOME/.ssh/id_ed25519" ] && SSH_CMD+=(-i "$REAL_HOME/.ssh/id_ed25519")

# ------------------------------------------------ 1. 主机网卡清单
sec "1. 主机网卡清单"
printf '  %-18s %-9s %-9s %-26s %s\n' "接口" "状态" "类型" "驱动" "地址"
for d in /sys/class/net/*; do
    i=$(basename "$d"); [ "$i" = "lo" ] && continue
    st=$(cat "$d/operstate" 2>/dev/null)
    drv=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)
    if [ -e "$d/wireless" ] || [ -e "$d/phy80211" ]; then ty="WLAN"; else ty="ETH"; fi
    # USB 设备单独标出来，方便确认新网卡是否被识别
    bus=""
    [ -n "${drv:-}" ] && grep -q "usb" "/sys/class/net/$i/device/uevent" 2>/dev/null && bus="[USB]"
    addr=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{printf "%s ", $4}')
    printf '  %-18s %-9s %-9s %-26s %s\n' "$i" "${st:-?}" "$ty$bus" "${drv:-?}" "${addr:-无}"
done
dim "如果新网卡没出现在这张表里：lsusb 看有没有设备、dmesg | tail 看驱动是否加载失败"

# ------------------------------------------------ 2. 关联状态
[ -z "$IFACE" ] && IFACE=$(iw dev 2>/dev/null | sed -n 's/^[[:space:]]*Interface \([^ ]*\)/\1/p' | head -1)
sec "2. 无线关联"
if [ -z "$IFACE" ]; then
    bad "找不到无线接口 —— 先把 WiFi 连到狗的热点"
    exit 1
fi
LINK=$(iw dev "$IFACE" link 2>/dev/null)
if printf '%s' "$LINK" | grep -q "^Connected to"; then
    ok "已关联 $IFACE"
    printf '%s\n' "$LINK" | sed -n 's/^Connected to /      BSSID : /p;s/^\tSSID: /      SSID  : /p;s/^\tfreq: /      频率  : /p;s/^\tsignal: /      信号  : /p;s/^\trx bitrate: /      收速率: /p;s/^\ttx bitrate: /      发速率: /p'
    FREQ=$(printf '%s' "$LINK" | sed -n 's/^\tfreq: //p')
    SIG=$(printf '%s' "$LINK" | sed -n 's/^\tsignal: \(-\{0,1\}[0-9]*\).*/\1/p')
    if [ "${FREQ:-0}" -gt 4000 ] 2>/dev/null; then
        ok "5 GHz（ch$(( (FREQ-5000)/5 ))）"
    else
        warn "2.4 GHz —— 传点云会明显吃力，建议在 App 里切 5 GHz"
    fi
    [ -n "${SIG:-}" ] && [ "$SIG" -lt -65 ] && warn "信号 ${SIG} dBm 偏弱（<-65），狗身上的金属壳会屏蔽天线，考虑换位置"
else
    bad "未关联任何 AP"
    exit 1
fi

# ------------------------------------------------ 3. 地址与省电
sec "3. 地址与省电"
IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1)
if [ -z "$IP" ]; then bad "$IFACE 没有 IPv4 地址（DHCP 没拿到）"; exit 1; fi
ADDR="${IP%/*}"; GW="${ADDR%.*}.1"
ok "$IFACE = $IP，网关 $GW（按 12.x 网段推导）"
PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $3}')
printf '  power_save = %s\n' "${PS:-未知}"
if [ "$PS" = "on" ] && [ "$KEEP_PS" -eq 0 ]; then
    if iw dev "$IFACE" set power_save off 2>/dev/null; then
        ok "已关闭省电（临时，重连后恢复 on）"
        dim "省电开着会让 RTT 从 2 ms 抖到 40 ms+，实时点云会一顿一顿"
    else
        warn "关闭失败，手动：sudo iw dev $IFACE set power_save off"
    fi
elif [ "$PS" = "on" ]; then
    warn "省电仍开着（--keep-ps），延迟会抖"
else
    ok "省电已关"
fi

# ------------------------------------------------ 4. 路由
sec "4. 到 ${DOG_NET} 的路由"
ROUTE_DEV=$(ip route get "$EDGE" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
ROUTE_VIA=$(ip route get "$EDGE" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
printf '  现在去 %s 走: dev=%s via=%s\n' "$EDGE" "${ROUTE_DEV:-?}" "${ROUTE_VIA:-直连}"

if [ "$CLEAN" -eq 1 ]; then
    ip route del "$DOG_NET" 2>/dev/null && ok "已删除 $DOG_NET 临时路由" || warn "没有可删的路由"
    exit 0
fi

ADDED=0
if [ "$ROUTE_DEV" != "$IFACE" ]; then
    warn "包没走无线口，丢给了 ${ROUTE_VIA:-默认网关} —— 这就是 ping 不通的直接原因"
    if [ "$ADD" -eq 0 ]; then
        dim "（--no-add）手动执行： sudo ip route add $DOG_NET via $GW dev $IFACE"
    elif ip route add "$DOG_NET" via "$GW" dev "$IFACE" 2>/dev/null; then
        ok "已临时添加 $DOG_NET via $GW dev $IFACE"
        ADDED=1
    else
        bad "添加失败。手动执行： sudo ip route add $DOG_NET via $GW dev $IFACE"
        exit 1
    fi
else
    ok "路由已指向 $IFACE"
fi

# 只有包真的从无线口出去，123 段的探测结果才有意义。
# 否则包被丢给默认网关（手机共享/家里路由），测出来的是"那边不通"，跟狗无关。
ROUTE_OK=0
if [ "$ROUTE_DEV" = "$IFACE" ] || [ "$ADDED" -eq 1 ]; then ROUTE_OK=1; fi

if [ "$KEEP_ROUTE" -eq 0 ]; then
    trap '[ "$ADDED" -eq 1 ] && ip route del "$DOG_NET" 2>/dev/null && echo "  （已移除本次临时路由；要保留用 --keep-route）"' EXIT
fi

# ------------------------------------------------ 4.5 运控转发能力
sec "4.5 运控转不转发"
# 关键：.161 通只能证明运控的 eth0 地址可达，不能证明它愿意转发别人的包。
# 目的地址是本机时走"本地交付"，压根不过 ip_forward 这道门。
# 拿一个 123 段里几乎不存在的地址去问它：
#   转发开着 → 它去 eth0 上 ARP，失败后回 ICMP「主机不可达」
#   没开转发 → 静默丢弃，纯超时，一个包都不回
FWD=0
if [ "$ROUTE_OK" -eq 0 ]; then
    warn "跳过：包没从无线口出去，测了也不算数"
    dim "先补路由： sudo ip route add $DOG_NET via $GW dev $IFACE"
else
fout=$(ping -c 3 -W 1 -i 0.5 "$FWD_TARGET" 2>&1)
funreach=$(printf '%s' "$fout" | sed -n 's/^From \([0-9.]*\).*Unreachable.*/\1/p' | sort -u | head -1)
floss=$(printf '%s' "$fout" | sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p')
if [ -n "$funreach" ]; then
    FWD=1
    ok "运控在转发（$funreach 对不存在的 $FWD_TARGET 回了 ICMP 不可达）"
elif [ "${floss:-100}" -eq 0 ]; then
    FWD=1
    warn "$FWD_TARGET 竟然通了 —— 这地址被占用，换个 FWD_TARGET 重测"
else
    warn "运控不转发：$FWD_TARGET 纯超时、无 ICMP 不可达 → 目的不在本机的包被静默丢弃"
fi
fi

# ------------------------------------------------ 5. 连通性
sec "5. 连通性"
# ICMP 不可达 vs 纯超时含义完全不同：
#   "From X Destination Host Unreachable" → X 说这地址不存在（没上电/没插线）
#   纯 100% 丢包                         → 包送到了，但对方回不来（回程路由问题）
LAST_UNREACH=""
probe() {
    local host="$1" label="$2" out loss unreach line avg mdev
    out=$(ping -c 3 -W 1 -i 0.3 "$host" 2>&1)
    loss=$(printf '%s' "$out" | sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p')
    unreach=$(printf '%s' "$out" | sed -n 's/^From \([0-9.]*\).*Unreachable.*/\1/p' | sort -u | head -1)
    LAST_UNREACH="$unreach"
    if [ "${loss:-100}" -eq 0 ]; then
        # 20 包细测抖动：首包已预热，不掺 ARP 的延迟
        line=$(ping -c 20 -W 1 -i 0.2 "$host" 2>/dev/null | tail -1)
        avg=$(printf '%s' "$line" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
        mdev=$(printf '%s' "$line" | sed -n 's|.*/\([0-9.]*\) ms$|\1|p')
        ok "$label $host 通  avg ${avg:-?} ms  抖动 ${mdev:-?} ms"
        awk -v m="${mdev:-0}" 'BEGIN{exit !(m+0>=5)}' && warn "    抖动 ${mdev} ms 偏大 —— 实时点云会顿，多半是同信道干扰"
        return 0
    fi
    if [ -n "$unreach" ]; then
        bad "$label $host 不通：$unreach 回 ICMP 不可达 → 设备不在（没上电/没插线）"
    else
        bad "$label $host 不通：纯超时、无 ICMP 不可达"
    fi
    return 1
}

probe "$GW" "网关     "; R_GW=$?
R_CTRL=2; R_EDGE=2; R_LIDAR=2; U_CTRL=""; U_EDGE=""; U_LIDAR=""
if [ "$ROUTE_OK" -eq 1 ]; then
    probe "$CTRL" "运控有线 "; R_CTRL=$?; U_CTRL="$LAST_UNREACH"
    probe "$EDGE" "拓展坞   "; R_EDGE=$?; U_EDGE="$LAST_UNREACH"
    probe "$LIDAR" "Mid360   "; R_LIDAR=$?; U_LIDAR="$LAST_UNREACH"
else
    warn "跳过 123 段：路由还在 ${ROUTE_DEV:-?} 上，包没从无线口出去"
fi

# ------------------------------------------------ 6. 端口与 SSH
sec "6. 端口与 SSH"
for hp in "$GW:22"; do
    h="${hp%:*}"; p="${hp#*:}"
    if timeout 4 bash -c "echo >/dev/tcp/$h/$p" 2>/dev/null; then ok "$h:$p 开"; else bad "$h:$p 不通"; fi
done
if [ "$ROUTE_OK" -eq 1 ]; then
    if timeout 4 bash -c "echo >/dev/tcp/$EDGE/22" 2>/dev/null; then ok "$EDGE:22 开"; else bad "$EDGE:22 不通"; fi
fi

if [ "$ROUTE_OK" -eq 0 ]; then
    warn "跳过 ssh：链路还没通到狗"
elif timeout 8 "${SSH_CMD[@]}" "$EDGE_USER@$EDGE" true 2>/dev/null; then
    ok "免密 ssh $EDGE_USER@$EDGE 可用"
    echo
    echo "  ── 狗端网卡（顺带确认新网卡是否被识别）──"
    timeout 10 "${SSH_CMD[@]}" "$EDGE_USER@$EDGE" \
        'ip -4 -o addr show | awk "{printf \"    %-8s %-20s %s\n\", \$2, \$4, \$NF}"; echo; lsusb | grep -iE "802|wireless|wlan|mediatek|realtek" || echo "    （lsusb 里没有无线设备）"' 2>/dev/null
else
    warn "ssh $EDGE_USER@$EDGE 不通（链路没通，或密钥没配）"
fi

# ------------------------------------------------ 7. 结论
sec "7. 结论"
if [ "$R_GW" -ne 0 ]; then
    bad "连热点网关都不通 —— 无线链路本身有问题，先解决关联/DHCP"
elif [ "${R_EDGE:-2}" -eq 2 ]; then
    warn "无法判定：12 段只通了网关，123 段没测到"
    dim "补上路由再跑一次： sudo ip route add $DOG_NET via $GW dev $IFACE"
elif [ "$R_EDGE" -eq 0 ]; then
    ok "通了：走狗的 AP 能直接摸到拓展坞 $EDGE"
    dim "运控在转发（NAT 或已有回程路由），狗端不用改任何东西"
    dim "下一步：./scripts/link_probe.sh 测带宽，或直接 ros2 topic list 看话题"
elif [ -n "${U_EDGE:-}" ] && [ "$U_EDGE" != "$EDGE" ]; then
    bad "拓展坞不在线：$U_EDGE 明确回了 ICMP「主机不可达」"
    dim "不是路由问题 —— 是设备没上网：没上电 / 网线没插 / 插错口"
elif [ "$R_CTRL" -eq 0 ] && [ "$FWD" -eq 0 ]; then
    bad "运控可达但不转发 —— 这条路（方案 C）在软件层走不通"
    dim "两条出路，都要运控密码："
    dim "  A) 开转发 + 放行 FORWARD，再给拓展坞加回程路由（那步仍要插一次网线）"
    dim "     ssh $GW → sudo sysctl -w net.ipv4.ip_forward=1 && sudo iptables -P FORWARD ACCEPT"
    dim "  B) 让运控做 NAT，拓展坞完全不用动（更干净）"
    dim "     sudo iptables -t nat -A POSTROUTING -o eth0 -s 192.168.12.0/24 -j MASQUERADE"
    dim "  ⚠ 方案 C 带宽与抖动都和 App 图传共用，长期跑点云不推荐"
elif [ "$R_CTRL" -eq 0 ]; then
    warn "运控会转发，但拓展坞不通 —— 缺的是回程路由"
    dim "包到了 $EDGE（没回 ICMP 不可达 → ARP 通、设备在线），但它不知道怎么回 192.168.12.0/24"
    dim "修法（插一次网线）：sudo ~/dog_wifi_return_route.sh --install"
else
    bad "运控两个网段都不通，链路到此为止"
fi

sec "备注"
dim "临时路由不写 NetworkManager 配置，重连/重启自动失效"
dim "--clean 手动清理；--keep-route 保留（跑 DDS 时用）"
