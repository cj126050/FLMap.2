#!/usr/bin/env bash
# =============================================================
#  wifi_route_probe.sh —— 验证「PC 走机器狗自己的热点，能不能摸到 192.168.123.x」
#
#  背景
#  ----
#  Go2 开 AP 直连模式时，PC 会拿到 192.168.12.x 的地址（狗当 DHCP）。
#  但 192.168.123.0/24 是狗的内部控制网段，拓展坞（.18）、运控（.161）、
#  雷达（.20）都在那边。两者之间隔着一层转发，能不能通取决于运控：
#    · 做 NAT / 有回程路由 → 通，方案 C 成立，狗端零改动
#    · 只做 AP 不转发       → 不通，需要登录运控加 NAT（要密码）
#    · 转发但无回程路由     → ping 不通，但能从狗端补一条路由救回来
#
#  为什么不能只 ping 就下结论
#  --------------------------
#  PC 上默认路由走的是别的网卡（手机 USB 共享 / 家里 Wi-Fi），
#  没有 192.168.123.0/24 的路由时，包会被丢给那个默认网关，
#  表现为"ping 不通"，但其实是自己的路由没配 —— 跟狗无关。
#  所以本脚本先补路由，再 ping，并按 网关 / 运控 / 拓展坞 三段分别判定。
#
#  用法
#  ----
#    sudo ./scripts/wifi_route_probe.sh              # 体检 + 临时补路由 + 判定
#    sudo ./scripts/wifi_route_probe.sh --no-add     # 只读，不改路由
#    sudo ./scripts/wifi_route_probe.sh --clean      # 删掉本脚本加的路由
#    sudo ./scripts/wifi_route_probe.sh --keep-ps    # 不动无线省电模式
#
#  路由是临时的，重启/重连即失效，不写任何配置文件。
# =============================================================
set -uo pipefail

DOG_NET="192.168.123.0/24"
GW_PORT=22
CTRL=192.168.123.161      # 运控
EDGE=192.168.123.18       # 拓展坞（Orin Nano）
LIDAR=192.168.123.20      # Mid360

ADD=1; CLEAN=0; KEEP_PS=0; IFACE="${WIFI_IFACE:-}"
for a in "$@"; do
    case "$a" in
        --no-add)   ADD=0 ;;
        --clean)    CLEAN=1 ;;
        --keep-ps)  KEEP_PS=1 ;;
        --iface=*)  IFACE="${a#*=}" ;;
        -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
sec() { printf '\n%s── %s%s\n' "$c_b" "$1" "$c_0"; }
ok()  { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim() { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }

printf '%s\n' "============================================================"
printf ' 无线链路体检   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ------------------------------------------------ 0. 找无线接口
[ -z "$IFACE" ] && IFACE=$(iw dev 2>/dev/null | sed -n 's/^[[:space:]]*Interface \([^ ]*\)/\1/p' | head -1)
if [ -z "$IFACE" ]; then bad "找不到无线接口（iw dev 为空）"; exit 1; fi

# ------------------------------------------------ 1. 关联状态
sec "1. 关联状态"
LINK=$(iw dev "$IFACE" link 2>/dev/null)
if printf '%s' "$LINK" | grep -q "^Connected to"; then
    ok "已关联 $IFACE"
    printf '%s\n' "$LINK" | sed -n 's/^Connected to /      BSSID: /p;s/^\tSSID: /      SSID : /p;s/^\tfreq: /      频率 : /p;s/^\tsignal: /      信号 : /p;s/^\ttx bitrate: /      速率 : /p'
    FREQ=$(printf '%s' "$LINK" | sed -n 's/^\tfreq: //p')
    if [ "${FREQ:-0}" -gt 4000 ] 2>/dev/null; then
        dim "5GHz（ch$(( (FREQ-5000)/5 ))），带宽比 2.4G 大得多，适合传点云"
    else
        warn "2.4GHz。传点云会明显吃力，改到 5GHz 热点再测"
    fi
else
    bad "未关联任何 AP —— 先把 Wi-Fi 连到狗的热点"
    exit 1
fi

# ------------------------------------------------ 2. 地址与网段
sec "2. 地址"
IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1)
if [ -z "$IP" ]; then bad "$IFACE 上没有 IPv4 地址（DHCP 没拿到？）"; exit 1; fi
PREFIX="${IP#*/}"; ADDR="${IP%/*}"
GW="${ADDR%.*}.1"
printf '  %-10s %s\n' "$IFACE" "$IP"
printf '  %-10s %s（按网段推导）\n' "网段网关" "$GW"

# ------------------------------------------------ 3. 省电模式
sec "3. 无线省电"
PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $3}')
printf '  power_save = %s\n' "${PS:-未知}"
if [ "$PS" = "on" ] && [ "$KEEP_PS" -eq 0 ]; then
    if iw dev "$IFACE" set power_save off 2>/dev/null; then
        ok "已关闭省电（重连后自动恢复 on，非持久改动）"
        dim "省电开着会让 RTT 从 ~2ms 抖到 40ms+，实时点云会一顿一顿的"
    else
        warn "关闭失败（权限不足），手动跑： sudo iw dev $IFACE set power_save off"
    fi
elif [ "$PS" = "on" ]; then
    warn "省电仍开着（--keep-ps），延迟会抖"
else
    ok "省电已关"
fi

# ------------------------------------------------ 4. 路由
sec "4. 路由"
ROUTE_DEV=$(ip route get "$EDGE" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
ROUTE_VIA=$(ip route get "$EDGE" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
printf '  去 %s 当前走: dev=%s via=%s\n' "$EDGE" "${ROUTE_DEV:-?}" "${ROUTE_VIA:-直连}"

NEED_ROUTE=0
[ "$ROUTE_DEV" != "$IFACE" ] && NEED_ROUTE=1

ADDED=0
if [ "$CLEAN" -eq 1 ]; then
    if ip route del "$DOG_NET" 2>/dev/null; then ok "已删除 $DOG_NET 的临时路由"
    else warn "没有可删的路由（可能本来就不存在）"; fi
    exit 0
fi

if [ "$NEED_ROUTE" -eq 1 ]; then
    warn "包没走无线口，而是丢给了 ${ROUTE_VIA:-默认网关} —— 这就是 ping 不通的直接原因"
    if [ "$ADD" -eq 0 ]; then
        dim "（--no-add）需要你手动执行："
        dim "sudo ip route add $DOG_NET via $GW dev $IFACE"
    elif ip route add "$DOG_NET" via "$GW" dev "$IFACE" 2>/dev/null; then
        ok "已临时添加 $DOG_NET via $GW dev $IFACE"
        ADDED=1
    else
        bad "添加失败（权限不足）。请自己执行："
        dim "sudo ip route add $DOG_NET via $GW dev $IFACE"
        dim "跑完再执行一次本脚本，或直接 ping 验证"
        exit 1
    fi
else
    ok "路由已指向 $IFACE，无需改动"
fi

trap '[ "$ADDED" -eq 1 ] && ip route del "$DOG_NET" 2>/dev/null && echo "  （已移除本次添加的临时路由）"' EXIT

# ------------------------------------------------ 5. 三段 ping
sec "5. 连通性（网关 → 运控 → 拓展坞 → 雷达）"
probe() {
    local host="$1" label="$2" n line avg mdev
    n=$(ping -c 3 -W 1 -i 0.3 "$host" 2>/dev/null | sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p')
    if [ "${n:-100}" -eq 0 ]; then
        line=$(ping -c 5 -W 1 -i 0.2 "$host" 2>/dev/null | tail -1)
        avg=$(printf '%s' "$line" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
        mdev=$(printf '%s' "$line" | sed -n 's|.*/\([0-9.]*\) ms$|\1|p')
        ok "$label $host 通（avg ${avg:-?} ms，抖动 ${mdev:-?} ms）"
        return 0
    fi
    bad "$label $host 不通（丢包 ${n:-100}%）"
    return 1
}

# 网关永远能测：它在本地网段
probe "$GW" "网关/热点侧"; R_GW=$?

# 123 段的三个地址，只有路由真正指向无线口时才有意义
if [ "$ROUTE_DEV" != "$IFACE" ] && [ "$ADDED" -eq 0 ]; then
    warn "跳过 123 段：路由还指向 ${ROUTE_DEV}，包根本没从无线口出去，测了也不算数"
    R_CTRL=2; R_EDGE=2; R_LIDAR=2
else
    probe "$CTRL" "运控      "; R_CTRL=$?
    probe "$EDGE" "拓展坞    "; R_EDGE=$?
    probe "$LIDAR" "Mid360    "; R_LIDAR=$?
fi

# ------------------------------------------------ 6. 判定
sec "6. 判定"
if [ "$R_GW" -ne 0 ]; then
    bad "连热点网关都不通 —— 无线链路本身有问题，先解决关联/DHCP"
elif [ "${R_CTRL:-2}" -eq 2 ]; then
    warn "无法判定：123 段没测到"
    dim "先补路由再来： sudo ip route add $DOG_NET via $GW dev $IFACE"
elif [ "$R_EDGE" -eq 0 ]; then
    ok "方案 C 成立：走狗的 AP 能直接摸到拓展坞 $EDGE"
    dim "运控在做转发（NAT 或已有回程路由），狗端不需要任何改动"
    dim "下一步：ssh unitree@$EDGE 看能否登录，再跑 ./scripts/link_probe.sh 测带宽"
elif [ "$R_CTRL" -eq 0 ]; then
    warn "运控 $CTRL 通，但拓展坞 $EDGE 不通 —— 运控会转发，缺的是**回程路由**"
    dim "包到达拓展坞时源地址是 $ADDR，它不知道怎么回 192.168.12.0/24，所以丢包"
    dim "修法（插上网线，在拓展坞上执行一次即可，重启失效）："
    dim "  sudo ip route add 192.168.12.0/24 via $CTRL dev eth0"
    dim "注意 via 必须是 $CTRL（运控），不是 192.168.123.1 —— 那个网关是幽灵路由"
elif ! timeout 2 bash -c "echo >/dev/tcp/$GW/$GW_PORT" 2>/dev/null; then
    bad "运控 $CTRL 也不通，热点网关的 $GW_PORT 端口也不开 —— 运控只在做 AP，不转发"
    dim "这条通路到此为止：要打通必须登录运控加 NAT，而运控密码目前未知"
else
    warn "运控 $CTRL 不通，但热点网关的 $GW_PORT 是开的 —— 运控在两个网段各有一个接口"
    dim "它认得 192.168.12.0/24，但不转发到 192.168.123.0/24"
    dim "想用这条路，只能登录 $GW 加一条转发/NAT"
fi

sec "备注"
dim "本脚本只做临时路由，不写 NetworkManager 配置；--clean 可手动清理"
dim "无线重连/重启后路由失效，属预期行为"
