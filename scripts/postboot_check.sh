#!/usr/bin/env bash
# 重启后（或热点重启后）一条命令判断「狗端能否自己连上无线」。
#
#   sudo ./scripts/postboot_check.sh                # 只体检，不动热点
#   sudo ./scripts/postboot_check.sh --start        # 热点没起就先起（含重载驱动）
#   sudo ./scripts/postboot_check.sh --wait=120     # 最多等 120 秒自动关联
#   sudo ./scripts/postboot_check.sh --dog          # 额外在狗端跑一次 link/stats
#
# 结论只有三种：
#   自动连上   → 以后重启不用插网线
#   热点没起   → 先跑 pc_hotspot.sh（唯一必须手动的一步）
#   超时未连上 → 插网线走 192.168.123.18 保底
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
IFACE="${IFACE:-wlp132s0}"
SSID="${SSID:-FLMap3}"
PC_IP="${PC_IP:-10.42.0.1}"
DOG_IP="${DOG_IP:-10.42.0.18}"
WIRED_PC="${WIRED_PC:-192.168.123.10}"
WIRED_DOG="${WIRED_DOG:-192.168.123.18}"
WAIT=90
START=0
DOGCMD=0

for a in "$@"; do
    case "$a" in
        --start)       START=1 ;;
        --dog)         DOGCMD=1 ;;
        --wait=*)      WAIT="${a#*=}" ;;
        --iface=*)     IFACE="${a#*=}" ;;
        --help|-h)     sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$a"; exit 2 ;;
    esac
done

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
sec() { printf '\n%s── %s%s\n' "$B" "$1" "$N"; }
ok()  { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
bad() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
dim() { printf '     %s%s%s\n' "$D" "$1" "$N"; }

printf '%s\n' "============================================================"
printf ' 重启后自检   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ---------------------------------------------- 1. 热点是否在跑
sec "1. PC 热点"
AP_UP=0
if iw dev "$IFACE" info 2>/dev/null | grep -q "type AP"; then
    AP_UP=1
    CUR=$(iw dev "$IFACE" info 2>/dev/null | awk '/ssid/{print $2}')
    CH=$(iw dev "$IFACE" info 2>/dev/null | awk '/channel/{print $2" ("$3" MHz)"}')
    ok "AP 已起  SSID=$CUR  ch$CH"
else
    MODE=$(iw dev "$IFACE" info 2>/dev/null | awk '/type/{print $2}')
    warn "没有 AP（$IFACE 当前 type=${MODE:-未知}）"
fi

if [ "$AP_UP" -eq 1 ]; then
    PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')
    [ "$PS" = "off" ] && ok "省电 off" || warn "省电 $PS —— rtw89 在省电开着时 AP 会静默，跑 pc_hotspot.sh 重设"
    ADDR=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}')
    [ -n "$ADDR" ] && ok "地址 $ADDR" || bad "热点口没有 IPv4 地址"
fi

if [ "$AP_UP" -eq 0 ] && [ "$START" -eq 1 ]; then
    dim "按 --start 要求启动热点（含重载 rtw89，清掉上次卡死的固件队列）"
    AP_UP=1
    if ! "$HERE/pc_hotspot.sh" --iface="$IFACE" --ssid="$SSID" --chan="${CHAN:-44}" --reload; then
        bad "热点启动失败，下面的等待没有意义"
        AP_UP=0
    fi
fi

if [ "$AP_UP" -eq 0 ]; then
    printf '\n%s结论：热点没起 —— 这是重启后唯一必须手动的一步%s\n' "$Y" "$N"
    printf '  cd ~/FLMap.2 && sudo ./scripts/pc_hotspot.sh --reload\n'
    printf '  然后重新跑： sudo ./scripts/postboot_check.sh\n'
    exit 10
fi

# ---------------------------------------------- 2. 有线是否还插着
sec "2. 有线口（判断是不是无线真的连上了）"
WIRED=0
if ip -4 -o addr show dev enp131s0 2>/dev/null | grep -q "$WIRED_PC"; then
    WIRED=1
    warn "enp131s0 仍有 $WIRED_PC —— 网线还插着"
    dim "狗端可能优先走有线，此时 ping 通不代表无线成功；"
    dim "要验证无线请拔掉网线（或看下一节的 $IFACE 关联客户端数）"
else
    ok "没有有线地址（无线是唯一通道，结论最可信）"
fi

# ---------------------------------------------- 3. 等狗端自动关联
sec "3. 等狗端自己连上（最多 ${WAIT}s）"
JOINED=0
T0=$(date +%s)
while :; do
    NSTA=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
    if [ "$NSTA" -ge 1 ] && ping -c1 -W1 "$DOG_IP" >/dev/null 2>&1; then
        JOINED=1
        break
    fi
    EL=$(( $(date +%s) - T0 ))
    [ "$EL" -ge "$WAIT" ] && break
    printf '\r     已等 %3ds  clients=%s  ping=%s   ' "$EL" "$NSTA" \
        "$(ping -c1 -W1 "$DOG_IP" >/dev/null 2>&1 && echo up || echo down)"
    sleep 5
done
printf '\r%*s\r' 60 ''

if [ "$JOINED" -eq 1 ]; then
    ok "狗端已自动关联并 ping 通 $DOG_IP"
    iw dev "$IFACE" station dump 2>/dev/null | awk '
        /^Station/{mac=$2}
        /signal:/{print "     "mac"  信号 "$2" dBm"}
        /rx bitrate:/{print "     "mac"  速率 "$3" "$4}'
    SIG=$(iw dev "$IFACE" station dump 2>/dev/null | awk '/signal:/{print $2; exit}')
    if [ -n "${SIG:-}" ] && [ "$SIG" -lt -70 ] 2>/dev/null; then
        warn "信号 $SIG dBm 偏弱，建图中途可能掉；把狗挪近或抬高天线"
    fi
else
    NSTA=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
    bad "${WAIT}s 内没有连上（当前关联客户端 $NSTA 个）"
    dim "先确认狗端：卡片上 wlan0 指示灯 / 或从有线 ssh 进去看 nmcli device status"
    dim "狗端 nmcli 会自动重试；若热点又静默，跑 sudo ./scripts/ap_watchdog.sh --once 体检"
fi

# ---------------------------------------------- 4. DDS / 点云
sec "4. DDS 与点云"
if command -v ros2 >/dev/null 2>&1 || [ -f /opt/ros/humble/setup.bash ]; then
    # shellcheck disable=SC1091
    source /opt/ros/humble/setup.bash 2>/dev/null
    [ -f "$HOME/dds_flmap.xml" ] && export CYCLONEDDS_URI="file://$HOME/dds_flmap.xml"
    export ROS_DOMAIN_ID=42
    NODE=$(timeout 8 ros2 node list 2>/dev/null | grep -c "unitree" || true)
    if [ "${NODE:-0}" -ge 1 ]; then
        ok "看到狗端节点 $NODE 个"
    else
        warn "没看到狗端节点（建图可能没 start）"
        dim "狗端启动： ssh -t unitree@$DOG_IP 'bash ~/flmap3_ws/scripts/edge_control.sh'"
    fi
else
    dim "未装 ROS，跳过"
fi

# ---------------------------------------------- 5. 结论
sec "结论"
if [ "$JOINED" -eq 1 ]; then
    printf '  %s以后重启不需要插网线%s —— 狗端 flmap-wifi 已 autoconnect=yes，\n' "$G" "$N"
    printf '  只要 PC 侧先把热点起来，狗端会在几十秒内自己连上。\n'
    if [ "$WIRED" -eq 1 ]; then
        printf '  %s但这次网线还插着，建议拔掉重跑本脚本，才算真验证过。%s\n' "$Y" "$N"
    fi
    printf '\n  接着建图：\n'
    printf '    ssh -t unitree@%s '"'"'bash ~/flmap3_ws/scripts/edge_control.sh'"'"'\n' "$DOG_IP"
    printf '    ./scripts/pc_view.sh\n'
else
    printf '  %s这次要插网线%s —— 无线没自动连上，先用有线 192.168.123.18 把活干完，\n' "$Y" "$N"
    printf '  再用 dog_wlan_join.sh 补一次关联，下次重启就不用插了。\n'
    printf '\n  插线后：\n'
    printf '    sudo ./scripts/dog_wlan_join.sh\n'
    printf '    ping -c3 %s\n' "$DOG_IP"
fi
printf '\n'

# ---------------------------------------------- 6. 可选：狗端内部状态
if [ "$DOGCMD" -eq 1 ]; then
    HOST="$DOG_IP"
    ping -c1 -W1 "$DOG_IP" >/dev/null 2>&1 || HOST="$WIRED_DOG"
    sec "6. 狗端内部（$HOST）"
    if ping -c1 -W1 "$HOST" >/dev/null 2>&1; then
        ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null "unitree@$HOST" \
            'echo "--- wlan0 ---"; iw dev wlan0 link 2>/dev/null | sed -n "1,6p"; \
             ip -4 -o addr show dev wlan0 | awk "{print \"ADDR=\" \$4}"; \
             echo "--- 网卡 ---"; nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null | grep wlan0' \
            2>/dev/null | grep -v -i "warning: perm"
    else
        bad "狗端两个地址都不通"
    fi
fi
