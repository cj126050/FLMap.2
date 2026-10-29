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
RELOAD=0                # --reload：重载 rtw89 模块（固件 TX 队列卡死时）

for a in "$@"; do
    case "$a" in
        --ssid=*) SSID="${a#*=}" ;;
        --pass=*) PASS="${a#*=}" ;;
        --chan=*) CHAN="${a#*=}" ;;
        --addr=*) ADDR="${a#*=}" ;;
        --iface=*) IFACE="${a#*=}" ;;
        --down)   DOWN=1 ;;
        --reload) RELOAD=1 ;;
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

# ------------------------------------------------ 0. 可选：重载驱动
# rtw89 每次 AP 启停都会报 "timed out to flush queues"，反复启停几次后固件
# TX 队列会卡死：AP 仍显示 type AP / carrier=1，但再也不发 beacon，重启热点
# 也救不回来，只能重载模块。
if [ "$RELOAD" -eq 1 ]; then
    sec "0. 重载 rtw89 驱动"
    nmcli connection down "$CON" 2>/dev/null
    if modprobe -r rtw89_8922ae_git rtw89_8922a_git rtw89_pci_git 2>/dev/null; then
        ok "已卸载 rtw89 模块"
    else
        warn "卸载失败（有进程占用），继续走普通重建"
    fi
    sleep 2
    if modprobe rtw89_8922ae_git 2>/dev/null; then
        ok "已重新加载 rtw89_8922ae_git"
    else
        bad "重新加载失败 —— 重启一次机器最稳"
    fi
    sleep 5
fi

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
# 顺序很关键：先断开 STA，再看监管域和信道。
# 因为 iw list 报的是「每个 phy 各自的 regd」，而网卡一旦关联到某个 AP，
# 那个 AP 的 country IE 就会覆盖全局设置。现场 VGE_1（ch52 / 80 MHz）就会把
# 5 GHz 功率从 23 dBm 压到 20 dBm，甚至让 ch44 整行从 iw list 里消失 ——
# 这时脚本会误判成「监管域限制」，其实是 AP 的 IE 在起作用。
CUR_SSID=$(iw dev "$IFACE" link 2>/dev/null | awk '/^Connected/{f=1} f&&/SSID/{print $2; exit}')
if [ -n "$CUR_SSID" ]; then
    nmcli device disconnect "$IFACE" >/dev/null 2>&1
    sleep 2
    ok "已断开原 STA 连接（$CUR_SSID）"
    dim "开热点必然踢掉它；断开后 phy 的 regd 才会回到全局设置"
fi

# 监管域是 5 GHz AP 最常见的拦路虎：
# country 00 时 5 GHz 整段标 PASSIVE-SCAN，内核不允许主动发 beacon，
# wpa_supplicant 报 "Failed to start AP functionality"，NM 只留下 reason 'none'。
# 注意 iw reg set 只是「运行时」设置：重载 rtw89、或关联到别的 AP 都会被冲掉，
# 所以每次开热点都重新设一遍，不要指望它自己保持。
if [ "$CHAN" -ge 36 ]; then
    REG=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -1)
    printf '  监管域 = %s\n' "${REG:-未知}"
    if [ "$REG" != "CN" ]; then
        if iw reg set CN 2>/dev/null; then
            sleep 1
            REG=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -1)
            ok "已设为 CN（监管域 $REG）"
        else
            bad "设置监管域失败，5 GHz AP 起不来"
            dim "手动： sudo iw reg set CN ；或改用 2.4G： sudo $0 --chan=6"
            dim "想一劳永逸：内核参数加 cfg80211.ieee80211_regdom=CN 后重启"
        fi
    else
        ok "监管域已是 CN"
    fi
fi

# 三种情况必须分开看，混成一句「监管域限制」会把人带到沟里：
#   a) 频率行根本不存在   → phy 没把 Band 2 报全，多是固件/队列卡死，不是监管域
#   b) 频率行带 disabled / no IR → 才是真·监管域不让发 beacon
#   c) 有频率行且无标记   → 合法可用
if [ "$CHAN" -ge 36 ]; then
    FREQ=$((5000 + CHAN * 5))
    FLINE=$(iw list 2>/dev/null | grep -F "${FREQ} MHz [${CHAN}]" | head -1)
    if [ -z "$FLINE" ]; then
        warn "iw list 里查不到 ch$CHAN（$FREQ MHz）"
        dim "Band 2 没报全：可能是固件/队列卡住 → sudo $0 --reload"
        dim "也可能是刚断开的 AP 还留着 regd 覆盖 → 等 5 秒重跑一次"
    elif printf '%s' "$FLINE" | grep -qiE "disabled|no IR|passive"; then
        warn "ch$CHAN 被监管域拦下：$(printf '%s' "$FLINE" | sed 's/^[[:space:]]*\*//')"
        dim "换 ch36/40 或退回 2.4G： sudo $0 --chan=6"
    else
        ok "ch$CHAN（$FREQ MHz）可用：$(printf '%s' "$FLINE" | sed 's/^[[:space:]]*\*//')"
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
    802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASS" \
    ipv4.method shared \
    ipv4.addresses "$ADDR" >/dev/null 2>&1 || { bad "建连接失败"; exit 1; }
ok "已创建 $CON（AP / 5GHz / ch$CHAN / $ADDR）"

if timeout 90 nmcli connection up "$CON" >/dev/null 2>&1; then
    ok "热点已启动（$BAND / ch$CHAN）"
else
    bad "热点启动失败"
    # reason 'none' 是 NM 在「不知道具体原因」时的兜底值，本身没有信息量。
    # 真正有用的线索在它前面几行：wpa_supplicant 拒绝起 AP / dnsmasq 抢不到端口 /
    # 固件 flush 超时。所以这里直接把过滤后的原始日志打出来。
    WHY=$(journalctl -u NetworkManager -n 200 --no-pager 2>/dev/null \
          | grep -iE "failed to start ap|ap functionality|supplicant|dnsmasq|deauth|reason '" \
          | tail -8)
    if [ -n "$WHY" ]; then
        dim "── NM 关键日志 ──"
        printf '%s\n' "$WHY" | sed 's/^/     /'
    else
        dim "── NM 末尾 12 行（没匹配到关键字）──"
        journalctl -u NetworkManager -n 12 --no-pager 2>/dev/null | sed 's/^/     /'
    fi
    DMESG=$(dmesg 2>/dev/null | grep -iE "rtw89|firmware|flush|beacon" | tail -6)
    if [ -n "$DMESG" ]; then
        dim "── 驱动日志 ──"
        printf '%s\n' "$DMESG" | sed 's/^/     /'
    fi
    if [ "$CHAN" -ge 36 ]; then
        dim "按概率排的下一步："
        dim "  1) 固件队列卡死（反复启停后最常见，日志里会有 timed out to flush queues）"
        dim "     sudo $0 --reload"
        dim "  2) 换个信道试（现场 ch36/40 通常空着）"
        dim "     sudo $0 --chan=36"
        dim "  3) 退回 2.4G（一定能起，只是带宽差）"
        dim "     sudo $0 --chan=6"
    else
        dim "2.4G 也起不来，多半是驱动状态问题： sudo $0 --reload"
    fi
    exit 1
fi

# 省电必须在 up 之后关：NM 激活连接时会把 iw 的设置重置回 on。
# rtw89 的 AP 在省电打开时会「起得来但几分钟后停发 beacon」——狗端表现为掉线，
# 而 PC 侧 iw 依然显示 type AP，极难从主机侧看出来。
iw dev "$IFACE" set power_save off 2>/dev/null
PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')
if [ "$PS" = "on" ]; then
    warn "省电仍为 on —— rtw89 会在几分钟后静默丢 beacon"
    dim "处置：sudo iw dev $IFACE set power_save off"
    dim "     并起守护：sudo ./scripts/ap_watchdog.sh"
else
    ok "省电已关（$PS）"
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
if [ "$CHAN" -le 14 ]; then BANDTXT="2.4 GHz"; else BANDTXT="5 GHz"; fi
printf '  %-10s %s\n' "信道" "ch$CHAN（$BANDTXT）"
printf '  %-10s %s\n' "网关" "${ADDR%/*}"

sec "下一步"
dim "1) 狗端连上来（需先插一次网线）："
dim "     sudo ./scripts/dog_wlan_join.sh"
dim "2) 拔网线，验证："
dim "     ping -c3 10.42.0.18 && ssh unitree@10.42.0.18"
warn "3) 热点是本次新建的 —— 狗端**之前**起的节点必须重启，否则收不到点云"
dim "     原因：CycloneDDS 的 socket 绑在旧连接上，进程还活着但发不出去。"
dim "     现象：狗端 bridge.log 照旧刷 10 Hz，PC 端 /flmap/cloud 却一条都没有。"
dim "     做法：狗端 scripts/edge_control.sh 里先 stop 再 start（或直接重跑）。"
dim "4) 之后所有脚本加 EDGE_HOST=10.42.0.18："
dim "     EDGE_HOST=10.42.0.18 ./scripts/link_probe.sh"
dim "关热点： sudo $0 --down"
