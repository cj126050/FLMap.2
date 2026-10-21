#!/usr/bin/env bash
# =============================================================
#  ap_chan_probe.sh —— 逐个信道重开热点，并从狗端验证 SSID 是否可见
#
#  解决什么
#  --------
#  狗端 STA 报 SCAN_MISS（扫不到 FLMap3），但 PC 侧 iw 显示 AP 正常。
#  常见原因只有三类：
#    1) 该信道对狗端 STA 不可用（5.7G 被动扫描 / 监管域）
#    2) 网卡 AP 模式在该信道起不来（rtw89/rtw88 在部分信道有这问题）
#    3) 距离太近，狗端接收前端被 23 dBm 压制
#
#  这个脚本把 1/2 自动化掉：换一个信道 → 等 beacon 起来 → 从狗端
#  （走有线 ssh）扫一次 → 命中就停在那个信道，并把结果打出来。
#
#  前提
#  ----
#    · PC 已用网线连到狗： ping 192.168.123.18 通、ssh 免密可用
#    · 狗端 wlan0 处于 station 模式（脚本会尝试恢复）
#
#  用法
#  ----
#    sudo ./scripts/ap_chan_probe.sh                  # 默认 36,44,48,149,6
#    sudo ./scripts/ap_chan_probe.sh --chans=36,6
#    sudo ./scripts/ap_chan_probe.sh --tx=300         # 同时把热点降到 3 dBm
# =============================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PC_IFACE="${WIFI_IFACE:-wlp132s0}"
SSID="${SSID:-FLMap3}"
PASS="${PASS:-flmap2026}"
EDGE="${EDGE:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"
CHANS="36,44,48,149,6"
SETTLE=8
TXPOWER=""

for a in "$@"; do
    case "$a" in
        --chans=*) CHANS="${a#*=}" ;;
        --ssid=*)  SSID="${a#*=}" ;;
        --pass=*)  PASS="${a#*=}" ;;
        --edge=*)  EDGE="${a#*=}" ;;
        --iface=*) PC_IFACE="${a#*=}" ;;
        --tx=*)    TXPOWER="${a#*=}" ;;
        --settle=*) SETTLE="${a#*=}" ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
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

# sudo 下 HOME=/root，ssh 找不到用户的密钥
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -n "${REAL_HOME:-}" ] || REAL_HOME="$HOME"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$REAL_HOME/.ssh/known_hosts")
[ -f "$REAL_HOME/.ssh/id_ed25519" ] && SSH_OPTS+=(-i "$REAL_HOME/.ssh/id_ed25519")
SSH=(ssh "${SSH_OPTS[@]}" "$EDGE_USER@$EDGE")

printf '%s\n' "============================================================"
printf ' 热点信道探测   %s\n' "$(date '+%F %T')"
printf ' SSID=%s  候选信道=%s\n' "$SSID" "$CHANS"
printf '%s\n' "============================================================"

sec "0. 前置检查"
timeout 6 "${SSH[@]}" true 2>/dev/null || {
    bad "ssh $EDGE_USER@$EDGE 不通 —— 先插网线，跑 ./scripts/dog_wlan_probe.sh --keep"
    exit 1
}
ok "有线到狗可用"
WLAN=$(timeout 15 "${SSH[@]}" 'for w in /sys/class/net/*; do [ -e "$w/wireless" ] && basename "$w"; done' 2>/dev/null | head -1)
[ -n "$WLAN" ] || { bad "狗端没有无线接口"; exit 1; }
ok "狗端无线接口 $WLAN"
# 保证狗端网卡处于 station 模式且未被 NM 停用
timeout 20 "${SSH[@]}" "sudo -n nmcli device set $WLAN managed yes 2>/dev/null;
    sudo -n ip link set $WLAN down 2>/dev/null;
    sudo -n iw dev $WLAN set type managed 2>/dev/null;
    sudo -n ip link set $WLAN up 2>/dev/null; true" >/dev/null 2>&1
ok "狗端 $WLAN 已恢复 station 模式"

# 从狗端扫一次，判断 SSID 是否可见；打印频点与信号
scan_edge() {
    timeout 40 "${SSH[@]}" "sudo -n iw dev $WLAN scan 2>/dev/null" 2>/dev/null \
    | awk -v want="$SSID" '
        /^BSS/ { bssid=$2; freq=0; sig=""; ssid=""; hit=0; next }
        /freq:/ { freq=$2 }
        /signal:/ { sig=$2 }
        /SSID:/ {
            sub(/^[ \t]*SSID:[ \t]*/, "")
            ssid=$0
            if (ssid == want) { print "HIT", freq, sig, bssid }
        }'
}

FOUND=""
for ch in ${CHANS//,/ }; do
    sec "ch$ch"
    "$HERE/pc_hotspot.sh" --iface="$PC_IFACE" --ssid="$SSID" --pass="$PASS" --chan="$ch" \
        >/dev/null 2>&1
    if [ -n "$TXPOWER" ]; then
        iw dev "$PC_IFACE" set txpower fixed "$TXPOWER" 2>/dev/null \
            && dim "已把热点发射功率限制为 $TXPOWER（0.01 dBm 单位）"
    fi
    dim "等 beacon 起稳 ${SETTLE}s ..."
    sleep "$SETTLE"

    RES=$(scan_edge)
    N5=$(timeout 20 "${SSH[@]}" "sudo -n iw dev $WLAN scan 2>/dev/null | grep -c 'freq: 5' || true" 2>/dev/null)
    N5=${N5:-0}
    if [ -n "$RES" ]; then
        read -r _ f s b <<<"$(printf '%s' "$RES" | head -1)"
        ok "狗端扫到 $SSID：ch$ch ($f MHz) 信号 $s dBm  BSSID $b"
        FOUND="$ch"
        break
    fi
    bad "狗端仍看不到 $SSID（本次 5G 频点条目 $N5 个，说明 5G 接收本身正常）"
done

sec "结果"
if [ -n "$FOUND" ]; then
    ok "可用信道 ch$FOUND —— 热点已停在该信道"
    dim "接着在狗端跑："
    dim "    ssh -t $EDGE_USER@$EDGE 'bash ~/flmap3_ws/scripts/dog_wlan_join.sh --ssid=$SSID --pass=$PASS'"
    dim "或从本机直接跑： sudo ./scripts/dog_wlan_join.sh"
    dim "验证： ping -c3 10.42.0.18"
    exit 0
fi

warn "所有候选信道都扫不到 $SSID —— 不是信道问题，按下面顺序查"
dim "1) 距离/饱和：把狗挪到离 PC 1.5–2 m 远，再跑一次（狗端前端被近距离强信号压住也会全漏）"
dim "2) 低功率再试： sudo $0 --chans=36,44 --tx=300"
dim "3) 2.4G 兜底：  sudo $0 --chans=6,11"
dim "4) 还是不行 → 热点这道 AP 模式在 rtw89 上不成立，改用便携路由器做中继"
dim "   热点已恢复到 ch44"
"$HERE/pc_hotspot.sh" --iface="$PC_IFACE" --ssid="$SSID" --pass="$PASS" --chan=44 >/dev/null 2>&1
exit 1
