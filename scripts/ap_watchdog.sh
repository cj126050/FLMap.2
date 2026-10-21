#!/usr/bin/env bash
# =============================================================
#  ap_watchdog.sh —— 热点守护：狗端掉线就重启 AP
#
#  为什么需要它
#  ------------
#  RTL8922AE（rtw89）作 AP 时会「起得来，但过几分钟停发 beacon」：
#  主机侧 iw 依然显示 type AP / carrier=1，狗端却完全扫不到，
#  只能在主机侧 ping 狗端才能发现。内核日志里能看到的伴随现象是
#    rtw89_8922ae_git: timed out to flush queues
#  以及 802-11-wireless.powersave 在连接激活后被重置回 on。
#
#  这个脚本每 N 秒 ping 一次狗端，连续失败就重开热点并把省电重新关掉。
#
#  前提
#  ----
#    · PC 已开热点，狗端已连上（10.42.0.18 可 ping）
#    · root（要重开热点）
#
#  用法
#  ----
#    sudo ./scripts/ap_watchdog.sh                 # 前台守护（Ctrl-C 退出）
#    sudo nohup ./scripts/ap_watchdog.sh &         # 后台
#    sudo ./scripts/ap_watchdog.sh --once          # 只体检一次，适合排查
#    sudo ./scripts/ap_watchdog.sh --stop          # 停掉后台守护
#    sudo ./scripts/ap_watchdog.sh --interval=5 --fail=3
# =============================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IFACE="${WIFI_IFACE:-wlp132s0}"
SSID="${SSID:-FLMap3}"
PASS="${PASS:-flmap2026}"
CHAN="${CHAN:-44}"
EDGE="${EDGE:-10.42.0.18}"
INTERVAL=10
FAILN=3
LOG="/var/log/flmap-ap-watchdog.log"
ONCE=0
STOP=0
PIDFILE=/run/flmap-ap-watchdog.pid
RELOAD_AFTER=2        # 连续 N 次重启仍不恢复，就改走 --reload 重载驱动

for a in "$@"; do
    case "$a" in
        --interval=*) INTERVAL="${a#*=}" ;;
        --fail=*)     FAILN="${a#*=}" ;;
        --edge=*)     EDGE="${a#*=}" ;;
        --chan=*)     CHAN="${a#*=}" ;;
        --ssid=*)     SSID="${a#*=}" ;;
        --pass=*)     PASS="${a#*=}" ;;
        --iface=*)    IFACE="${a#*=}" ;;
        --log=*)      LOG="${a#*=}" ;;
        --reload-after=*) RELOAD_AFTER="${a#*=}" ;;
        --once)       ONCE=1 ;;
        --stop)       STOP=1 ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim()  { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >>"$LOG"; }

[ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo $0 $*"; exit 1; }

if [ "$STOP" -eq 1 ]; then
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" && ok "已停止守护（pid $(cat "$PIDFILE")）"
        rm -f "$PIDFILE"
    else
        warn "没有在跑的守护"
    fi
    exit 0
fi

# 省电一定要关：rtw89 在 PS 打开时 AP 会静默
ps_off() {
    iw dev "$IFACE" set power_save off 2>/dev/null
    local s
    s=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')
    [ "$s" = "on" ] && return 1 || return 0
}

alive() { ping -c 2 -W 1 "$EDGE" >/dev/null 2>&1; }

restart_ap() {
    local extra="${1:-}"
    log "重启热点 ch$CHAN（$SSID）${extra:+ $extra}"
    "$HERE/pc_hotspot.sh" --iface="$IFACE" --ssid="$SSID" --pass="$PASS" --chan="$CHAN" $extra \
        >>"$LOG" 2>&1
    ps_off || log "警告：省电仍为 on"
    sleep 12
}

printf '%s\n' "============================================================"
printf ' 热点守护   %s\n' "$(date '+%F %T')"
printf ' 目标 %s   间隔 %ss   连败阈值 %s   信道 ch%s\n' "$EDGE" "$INTERVAL" "$FAILN" "$CHAN"
printf ' 日志 %s\n' "$LOG"
printf '%s\n' "============================================================"

if [ "$ONCE" -eq 1 ]; then
    iw dev "$IFACE" info 2>/dev/null | awk '/type|channel|txpower/{printf "     %s\n", $0}'
    if ps_off; then ok "省电 off"; else bad "省电 on（rtw89 会在几分钟后静默）"; fi
    if alive; then ok "$EDGE 可达"; else bad "$EDGE 不可达 —— 需要重启热点"; fi
    exit $?
fi

# 起守护前先确认一次，避免在没连上的情况下反复重开热点
if ! alive; then
    bad "$EDGE 不可达 —— 先让狗端连上热点，再起守护"
    dim "  sudo ./scripts/dog_wlan_join.sh"
    dim "  ping -c3 $EDGE"
    exit 1
fi
ps_off || warn "省电关不掉，靠后续每轮重试"

log "守护启动 pid=$$ 目标=$EDGE 间隔=${INTERVAL}s 阈值=$FAILN ch=$CHAN"
echo $$ >"$PIDFILE"

fails=0
restarts=0
unrec=0            # 连续"重启了但没恢复"的次数
while :; do
    if alive; then
        if [ "$fails" -ne 0 ]; then
            ok "$EDGE 恢复"
            log "链路恢复"
        fi
        fails=0
        unrec=0
    else
        fails=$((fails + 1))
        warn "$EDGE 不通（$fails/$FAILN）"
        if [ "$fails" -ge "$FAILN" ]; then
            log "连续 $fails 次不通，判定 hotspot 静默"
            unrec=$((unrec + 1))
            if [ "$unrec" -ge "$RELOAD_AFTER" ]; then
                bad "判定 AP 静默 → 重载驱动后重开（连续 $unrec 次重启无效）"
                restart_ap "--reload"
                unrec=0
            else
                bad "判定 AP 静默 → 重启热点"
                restart_ap
            fi
            restarts=$((restarts + 1))
            fails=0
            if alive; then
                ok "重启后 $EDGE 已恢复（累计重启 $restarts 次）"
                log "重启后恢复，累计 $restarts"
            else
                warn "重启后仍未恢复，等狗端自动重连"
            fi
        fi
    fi
    # 每轮顺手把省电按回去（NM/固件有时会自己打开）
    ps_off || true
    sleep "$INTERVAL"
done
