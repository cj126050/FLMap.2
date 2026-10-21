#!/usr/bin/env bash
# =============================================================
#  pc_hotspot.sh —— 把 PC 的无线网卡变成热点，让狗连上来
#
#  为什么是这条路
#  --------------
#  网卡插在狗上（方案 A）。狗端网卡做 STA 比做 AP 省事得多：
#  做 AP 要装 hostapd + dnsmasq，而狗端没有外网，装包基本没戏。
#  PC 这边一块支持 AP 模式的网卡 + NetworkManager，一条命令就能开热点。
#
#  为什么网段选 10.42.0.0/24
#  -------------------------
#  狗端 eth0 已经占了 192.168.123.18，如果热点还发 123 段，狗端就有两个
#  接口同网段，ARP 和路由会互相打架（回包从 eth0 出去，PC 永远收不到）。
#  换一个干净网段，PC 和狗在 WiFi 这一跳里就是普通的两台主机，
#  DDS 发现不用跨网段、不用 NAT、不用回程路由。
#
#  用法
#  ----
#    sudo ./scripts/pc_hotspot.sh                  # 默认 SSID FLMap3 / 密码 flmap2026
#    sudo ./scripts/pc_hotspot.sh --ssid=Go2Wifi --pass=12345678 --chan=44
#    sudo ./scripts/pc_hotspot.sh --down           # 关掉热点，恢复原来的 WiFi
#
#  注意：开热点会踢掉当前 WiFi 连接（主机现在连的是狗自带 AP）。
#        公网走手机 USB 共享，不受影响。
# =============================================================
set -uo pipefail

IFACE="${WIFI_IFACE:-wlp132s0}"
CON="flmap-hotspot"
SSID="FLMap3"
PASS="flmap2026"
CHAN=44                 # 5 GHz 非 DFS；现场 ch149 被 VGE_5 占着，ch48 被 VGE_0_5G 占着
ADDR="10.42.0.1/24"
DOWN=0

for a in "$@"; do
    case "$a" in
        --ssid=*) SSID="${a#*=}" ;;
        --pass=*) PASS="${a#*=}" ;;
        --chan=*) CHAN="${a#*=}" ;;
        --addr=*) ADDR="${a#*=}" ;;
        --iface=*) IFACE="${a#*=}" ;;
        --down)   DOWN=1 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
sec()  { printf '\n%s── %s%s\n' "$c_b" "$1" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim()  { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }

[ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo $0 $*"; exit 1; }
command -v nmcli >/dev/null || { bad "没有 nmcli"; exit 1; }

# ------------------------------------------------ 关掉热点
if [ "$DOWN" -eq 1 ]; then
    sec "关闭热点"
    nmcli connection down "$CON" 2>/dev/null && ok "已断开 $CON" || warn "$CON 本来就没开"
    nmcli connection delete "$CON" 2>/dev/null && ok "已删除 $CON" || true
    ip route del 239.255.0.1/32 dev "$IFACE" 2>/dev/null && ok "已移除 DDS 多播路由"
    dim "现在可以重新连原来的 WiFi：nmcli device wifi connect <SSID> password <密码>"
    exit 0
fi

printf '%s\n' "============================================================"
printf ' PC 热点   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ------------------------------------------------ 1. 前置检查
sec "1. 网卡能力"
if [ ! -e "/sys/class/net/$IFACE/wireless" ] && [ ! -e "/sys/class/net/$IFACE/phy80211" ]; then
    bad "$IFACE 不是无线接口"
    dim "列表：iw dev"
    exit 1
fi
if iw list 2>/dev/null | sed -n '/Supported interface modes/,/Band 1/p' | grep -qw "AP"; then
    ok "$IFACE 支持 AP 模式"
else
    bad "$IFACE 不支持 AP 模式，这条路走不通"
    dim "备选：狗端开 AP（要 hostapd + dnsmasq，狗端无外网装不了）"
    dim "      或买一个便携路由器做中继（FLMap.2 方案 B）"
    exit 1
fi
if [ "$CHAN" -ge 36 ]; then
    if iw list 2>/dev/null | grep -q "$(printf '%s MHz \[%s\]' "$((5000 + CHAN*5))" "$CHAN")"; then
        ok "ch$CHAN（$((5000 + CHAN*5)) MHz）可用"
    else
        warn "ch$CHAN 当前不可用（监管域限制）"
    fi
fi

# 监管域是 5 GHz AP 最常见的拦路虎：
# country 00 时 5 GHz 整段标 PASSIVE-SCAN，内核不允许主动发 beacon，
# wpa_supplicant 会直接报 "Failed to start AP functionality"，而 NM 只会
# 说 "supplicant-timeout" —— 从表象完全看不出是监管域的问题。
REG=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -1)
printf '  监管域 = %s\n' "${REG:-未知}"
if [ "$CHAN" -ge 36 ] && { [ "$REG" = "00" ] || [ -z "$REG" ]; }; then
    warn "country 00：5 GHz 全是 PASSIVE-SCAN，AP 起不来"
    if iw reg set CN 2>/dev/null; then
        sleep 1
        REG=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -1)
        ok "已设为 CN（监管域 $REG）"
    else
        bad "设置监管域失败，5 GHz AP 大概率起不来"
        dim "手动： sudo iw reg set CN"
        dim "或改用 2.4 GHz： sudo $0 --chan=6"
    fi
fi

# ------------------------------------------------ 2. 建热点
sec "2. 建立热点"
# 干净重建，避免残留配置把 mode/channel 锁死
nmcli connection down "$CON" 2>/dev/null
nmcli connection delete "$CON" 2>/dev/null

# 2.4 GHz 用 bg，5 GHz 用 a；写死 a 的话 --chan=6 会直接被 NM 拒掉
if [ "$CHAN" -le 14 ]; then BAND="bg"; else BAND="a"; fi

nmcli connection add type wifi ifname "$IFACE" con-name "$CON" ssid "$SSID" \
    connection.autoconnect no \
    802-11-wireless.mode ap \
    802-11-wireless.band "$BAND" \
    802-11-wireless.channel "$CHAN" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASS" \
    ipv4.method shared \
    ipv4.addresses "$ADDR" >/dev/null 2>&1 || { bad "建连接失败"; exit 1; }
ok "已创建 $CON（AP / 5GHz / ch$CHAN / $ADDR）"

# AP 模式下关掉省电，否则转发延迟会抖
iw dev "$IFACE" set power_save off 2>/dev/null && ok "省电已关"

if timeout 90 nmcli connection up "$CON" >/dev/null 2>&1; then
    ok "热点已启动（$BAND / ch$CHAN）"
else
    bad "热点启动失败"
    WHY=$(journalctl -u NetworkManager -n 60 --no-pager 2>/dev/null | grep -oE "reason '[a-z-]+'|Failed to start AP functionality" | tail -1)
    [ -n "$WHY" ] && dim "NM 报：$WHY"
    if [ "$CHAN" -ge 36 ]; then
        dim "5 GHz AP 起不来最常见两个原因："
        dim "  1) 监管域还是 00 → sudo iw reg set CN && sudo $0"
        dim "  2) 驱动不支持该信道的 AP → 退回 2.4G： sudo $0 --chan=6"
    else
        dim "看详细日志： journalctl -u NetworkManager -n 40 --no-pager"
    fi
    exit 1
fi

# ------------------------------------------------ 3. DDS 多播出口
# 主机的默认路由不在无线口上（上网走手机 USB / 其它网卡），内核就把 239.x 的多播
# 从那条默认路由发出去。结果：狗发的多播 PC 收得到（狗端默认路由在 wlan0），
# PC 发的多播狗永远收不到 —— DDS 发现变成单向，现象是"狗的话题 PC 看得见，
# PC 的话题狗看不见"，而 ping / ssh / scp 全都正常，极难往这里想。
#
# 修法是给 DDS 的发现多播地址单独指一条路由，只影响 239.255.0.1 这一个组，
# 不改变默认路由，也不影响上网。
sec "3. DDS 多播路由"
MC_GROUP="239.255.0.1"
if ip route show "$MC_GROUP/32" 2>/dev/null | grep -q "dev $IFACE"; then
    ok "$MC_GROUP 已经指向 $IFACE"
else
    ip route replace "$MC_GROUP/32" dev "$IFACE" 2>/dev/null \
        && ok "$MC_GROUP → $IFACE（DDS 发现走无线）" \
        || warn "加多播路由失败 —— 无线电 DDS 会退化成单向，跑 $0 时确认是用 sudo"
fi

# ------------------------------------------------ 4. 结果
sec "4. 结果"
ip -4 -o addr show dev "$IFACE" | awk '{printf "  %-10s %s\n", $2, $4}'
printf '  %-10s %s\n' "SSID" "$SSID"
printf '  %-10s %s\n' "密码" "$PASS"
printf '  %-10s %s\n' "信道" "ch$CHAN（5 GHz）"
printf '  %-10s %s\n' "网关" "${ADDR%/*}"

sec "下一步"
dim "1) 狗端连上来（需先插一次网线）："
dim "     sudo ./scripts/dog_wlan_join.sh"
dim "2) 拔网线，验证："
dim "     ping -c3 10.42.0.18 && ssh unitree@10.42.0.18"
dim "3) 之后所有脚本加 EDGE_HOST=10.42.0.18："
dim "     EDGE_HOST=10.42.0.18 ./scripts/link_probe.sh"
dim "关热点： sudo $0 --down"
