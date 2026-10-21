#!/usr/bin/env bash
# =============================================================
#  dog_wlan_probe.sh —— 插一次网线，确认狗端的 USB 无线网卡能不能用
#
#  为什么必须插网线
#  ----------------
#  当前唯一能到狗的路是「PC 连 Go2 自带 AP → 运控 → 拓展坞」，而运控不开转发
#  （实测 192.168.123.254 纯超时，无 ICMP 不可达），这条路在软件层是死的。
#  狗端的新网卡此刻还没有任何配置，也不可能自己连上来。
#  所以第一次配置绕不开一根网线，之后全程无线。
#
#  这个脚本只做两件事，不改狗端任何配置：
#    1. PC 侧临时配好有线地址，ssh 上去
#    2. 在狗端把「网卡有没有被认出来」查清楚：设备、驱动、固件、支持的模式
#
#  用法
#  ----
#    sudo ./scripts/dog_wlan_probe.sh              # 默认 enp131s0
#    sudo ./scripts/dog_wlan_probe.sh --iface=eth0
#    sudo ./scripts/dog_wlan_probe.sh --keep        # 保留 PC 的有线地址
#
#  网线接法：PC 的 enp131s0 → 拓展坞**朝外**那个 RJ45（不是狗身内部的口）
# =============================================================
set -uo pipefail

HOST_IF="${HOST_IF:-enp131s0}"
HOST_IP="192.168.123.10"
EDGE="192.168.123.18"
EDGE_USER="${EDGE_USER:-unitree}"
KEEP=0

for a in "$@"; do
    case "$a" in
        --iface=*) HOST_IF="${a#*=}" ;;
        --keep)    KEEP=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
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

# sudo 会把 HOME 改成 /root，ssh 就跑去找 /root/.ssh（不存在），表现为
# 「ping 得通但 ssh 连不上」。按 SUDO_USER 反查真实 home，显式指定密钥和
# known_hosts，避免踩这个坑。
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -n "${REAL_HOME:-}" ] || REAL_HOME="$HOME"
SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new
         -o "UserKnownHostsFile=$REAL_HOME/.ssh/known_hosts")
[ -f "$REAL_HOME/.ssh/id_ed25519" ] && SSH_CMD+=(-i "$REAL_HOME/.ssh/id_ed25519")

printf '%s\n' "============================================================"
printf ' 狗端无线网卡探测   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ------------------------------------------------ 1. 有线链路
sec "1. PC 有线口"
if [ ! -e "/sys/class/net/$HOST_IF" ]; then
    bad "没有 $HOST_IF —— 用 --iface= 指定实际网口"
    dim "网口清单：ip -br link"
    exit 1
fi
if [ "$(cat /sys/class/net/$HOST_IF/carrier 2>/dev/null || echo 0)" != "1" ]; then
    bad "$HOST_IF 没有载波 —— 网线没插好，或插到了狗身内部那个口"
    dim "换拓展坞朝外的 RJ45；插好后 cat /sys/class/net/$HOST_IF/carrier 应为 1"
    exit 1
fi
ok "$HOST_IF 载波正常"

ip link set "$HOST_IF" up
ip addr replace "$HOST_IP/24" dev "$HOST_IF"
if ip -4 -o addr show dev "$HOST_IF" | grep -q "$HOST_IP"; then
    ok "已配 $HOST_IP/24"
else
    bad "地址没配上，后面不用测了"
    exit 1
fi

if [ "$KEEP" -eq 0 ]; then
    trap 'ip addr del '"$HOST_IP"'/24 dev '"$HOST_IF"' 2>/dev/null && echo "  （已移除临时地址；--keep 可保留）"' EXIT
fi

# ------------------------------------------------ 2. 可达性
sec "2. 到狗端"
if ping -c 3 -W 2 "$EDGE" >/dev/null 2>&1; then
    ok "$EDGE 通"
else
    bad "$EDGE 不通"
    dim "先确认狗是开机状态（拓展坞指示灯/风扇）"
    exit 1
fi
if timeout 8 "${SSH_CMD[@]}" "$EDGE_USER@$EDGE" true 2>/dev/null; then
    ok "免密 ssh 可用"
else
    bad "ssh 不通，先 ssh-copy-id $EDGE_USER@$EDGE"
    exit 1
fi

# ------------------------------------------------ 3. 狗端网卡
sec "3. 狗端无线网卡"
REMOTE=$(cat <<'EOS'
echo "--- 网络接口 ---"
ip -br link | sed 's/^/    /'

echo
echo "--- USB 设备（找网卡）---"
lsusb | grep -viE "root hub|hub$" | sed 's/^/    /'

echo
echo "--- 网卡驱动 ---"
mods=$(lsmod 2>/dev/null | awk '{print $1}' | grep -iE "^(mt76|rtl8|8812|8821|88x2|r8188|mt7601|ath9k_htc|rt2800usb)" | tr '\n' ' ')
[ -n "$mods" ] && echo "    已加载: $mods" || echo "    没有加载任何 USB 无线驱动"

echo
echo "--- 无线接口 ---"
found=0
for w in /sys/class/net/*; do
    n=$(basename "$w")
    if [ -e "$w/wireless" ] || [ -e "$w/phy80211" ]; then
        found=1
        echo "    $n  up=$(cat $w/operstate)  mac=$(cat $w/address)"
    fi
done
[ "$found" -eq 0 ] && echo "    没有 wlan 接口"

echo
echo "--- 支持的接口模式（决定能不能开 AP）---"
for w in /sys/class/net/*; do
    if [ -e "$w/wireless" ] || [ -e "$w/phy80211" ]; then
        n=$(basename "$w")
        phy=$(basename "$(readlink -f "$w/phy80211")")
        echo "    [$n / $phy]"
        iw list 2>/dev/null | sed -n '/Supported interface modes/,/Band 1/p' | head -12 | sed 's/^/      /'
        break
    fi
done

echo
echo "--- 固件加载失败? ---"
dmesg 2>/dev/null | grep -iE "firmware.*(fail|error)|mt76|rtl8|usb.*disconnect" | tail -15 | sed 's/^/    /' || echo "    (dmesg 无权限或无相关记录)"
EOS
)

timeout 40 "${SSH_CMD[@]}" "$EDGE_USER@$EDGE" "$REMOTE" 2>&1 | sed 's/^/  /'

# ------------------------------------------------ 4. 判定
sec "4. 结论"
WLAN_N=$(timeout 15 "${SSH_CMD[@]}" "$EDGE_USER@$EDGE" \
    'for w in /sys/class/net/*; do [ -e "$w/wireless" ] && basename "$w"; done' 2>/dev/null | head -1)

if [ -n "$WLAN_N" ]; then
    ok "狗端有无线接口：$WLAN_N"
    dim "下一步：sudo ./scripts/pc_hotspot.sh 开热点，再在狗端连上去"
else
    bad "狗端没有 wlan 接口 —— 网卡没被识别"
    dim "按顺序排查："
    dim "  1) 网卡是否插稳（拓展坞体内金属壳，USB 口可能被挡）"
    dim "  2) lsusb 里有没有未知设备（有 ID 没名字 = 没驱动）"
    dim "  3) dmesg 里 firmware load failed = 缺固件，从 PC 拷："
    dim "     scp /lib/firmware/mediatek/mt7662u*.bin $EDGE_USER@$EDGE:/tmp/"
    dim "  4) 芯片不是 MT7612U（如 RTL8812AU）→ 内核无驱动，要 DKMS 编译"
fi
