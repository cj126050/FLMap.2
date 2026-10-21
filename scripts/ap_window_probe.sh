#!/usr/bin/env bash
# =============================================================
#  ap_window_probe.sh —— 量出「热点可见窗口」有多长
#
#  为什么需要
#  ----------
#  现场现象：pc_hotspot.sh 起来后，狗端有时 5 秒后就能扫到，有时几分钟后
#  就彻底消失；主机侧 iw 始终显示 type AP / carrier=1。要判断这只 AP 是
#  「起得慢」还是「起得来但会自己静默」，唯一可靠的办法是从狗端连续采样。
#
#  它做什么
#  --------
#    1) 重开热点（pc_hotspot.sh）
#    2) 立刻开始从狗端（走有线 ssh）每 ~5 秒扫一次，记下 SSID 是否出现、信号强度
#    3) 打印时间线 + 结论：可见窗口从第几秒到第几秒
#
#  用法
#  ----
#    sudo ./scripts/ap_window_probe.sh                 # 采样 120 秒
#    sudo ./scripts/ap_window_probe.sh --duration=180
#    sudo ./scripts/ap_window_probe.sh --chan=36
# =============================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IFACE="${WIFI_IFACE:-wlp132s0}"
SSID="${SSID:-FLMap3}"
PASS="${PASS:-flmap2026}"
CHAN="${CHAN:-44}"
DURATION=120
EDGE="${EDGE:-192.168.123.18}"
EDGE_USER="${EDGE_USER:-unitree}"

for a in "$@"; do
    case "$a" in
        --duration=*) DURATION="${a#*=}" ;;
        --chan=*)     CHAN="${a#*=}" ;;
        --ssid=*)     SSID="${a#*=}" ;;
        --pass=*)     PASS="${a#*=}" ;;
        --iface=*)    IFACE="${a#*=}" ;;
        --edge=*)     EDGE="${a#*=}" ;;
        -h|--help)    sed -n '2,27p' "$0"; exit 0 ;;
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

REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -n "${REAL_HOME:-}" ] || REAL_HOME="$HOME"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$REAL_HOME/.ssh/known_hosts")
[ -f "$REAL_HOME/.ssh/id_ed25519" ] && SSH_OPTS+=(-i "$REAL_HOME/.ssh/id_ed25519")
SSH=(ssh "${SSH_OPTS[@]}" "$EDGE_USER@$EDGE")

timeout 6 "${SSH[@]}" true 2>/dev/null || { bad "ssh $EDGE_USER@$EDGE 不通 —— 先插网线"; exit 1; }
WLAN=$(timeout 15 "${SSH[@]}" 'for w in /sys/class/net/*; do [ -e "$w/wireless" ] && basename "$w"; done' 2>/dev/null | head -1)
[ -n "$WLAN" ] || { bad "狗端没有无线接口"; exit 1; }

printf '%s\n' "============================================================"
printf ' 热点可见窗口探测   %s\n' "$(date '+%F %T')"
printf ' SSID=%s  ch%s  采样 %ss\n' "$SSID" "$CHAN" "$DURATION"
printf '%s\n' "============================================================"

sec "重开热点"
"$HERE/pc_hotspot.sh" --iface="$IFACE" --ssid="$SSID" --pass="$PASS" --chan="$CHAN" \
    | grep -E "已创建|已启动|省电|失败" | sed 's/^/  /'
T0=$(date +%s)

scan_once() {
    timeout 30 "${SSH[@]}" "sudo -n iw dev $WLAN scan 2>/dev/null" 2>/dev/null \
    | awk -v want="$SSID" '
        /^BSS/ { freq=0; sig=""; next }
        /freq:/ { freq=$2 }
        /signal:/ { sig=$2 }
        /SSID:/ {
            sub(/^[ \t]*SSID:[ \t]*/, "")
            if ($0 == want) { print "HIT", freq, sig }
        }'
}

sec "时间线（每行一次狗端扫描）"
first=""; last=""; n_hit=0; n_scan=0
while :; do
    t=$(( $(date +%s) - T0 ))
    [ "$t" -gt "$DURATION" ] && break
    res=$(scan_once)
    n_scan=$((n_scan + 1))
    if [ -n "$res" ]; then
        read -r _ f s <<<"$(printf '%s' "$res" | head -1)"
        n_hit=$((n_hit + 1))
        [ -z "$first" ] && first=$t
        last=$t
        printf '  t=%3ss  %s✓ 可见%s  ch%s  %s dBm\n' "$t" "$c_g" "$c_0" "$f" "$s"
    else
        printf '  t=%3ss  %s· 不可见%s\n' "$t" "$c_d" "$c_0"
    fi
    sleep 1
done

sec "结论"
printf '  采样 %d 次，命中 %d 次\n' "$n_scan" "$n_hit"
if [ "$n_hit" -eq 0 ]; then
    bad "整个 ${DURATION}s 内一次都没扫到 —— 不是窗口问题，AP 根本没发 beacon"
    dim "下一步：sudo ./scripts/ap_chan_probe.sh --chans=36,6,1  换个频段再判"
elif [ "$first" -le 8 ] && [ "$last" -ge $((DURATION - 20)) ]; then
    ok "全程可见（${first}s ~ ${last}s）—— 这次热点是好的，问题在别处"
    dim "直接跑： sudo ./scripts/dog_wlan_join.sh"
elif [ -n "$first" ] && [ "$last" -le $((first + 15)) ]; then
    warn "只在前 ${first}s ~ ${last}s 可见，之后静默 —— 确认是「AP 空闲自静默」"
    dim "对策：热点一起来就立刻连（dog_wlan_join 已内置 40s 重试循环）；"
    dim "      连上后保持心跳：sudo nohup ./scripts/ap_watchdog.sh --interval=10 &"
else
    warn "可见窗口 ${first}s ~ ${last}s，中间有断续 —— 记下时间线，按断续处理"
    dim "先跑： sudo ./scripts/ap_watchdog.sh --once   看省电与可达性"
fi
