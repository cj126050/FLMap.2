#!/usr/bin/env bash
# 狗端无线连不上的「一次问到底」诊断。
#
# 用法（在 PC 上跑，需要有线或无线能 ssh 到狗）：
#   ./scripts/dog_wifi_diag.sh                # 自动选地址（先无线后有线）
#   ./scripts/dog_wifi_diag.sh --host=192.168.123.18
#   ./scripts/dog_wifi_diag.sh --fix          # 发现可自动修的问题就顺手修
#
# 覆盖整条链：网卡枚举 → 驱动 → 接口 → rfkill → NM 托管 → profile
# → 能否扫到 FLMap3 → 能否关联。每步都给出「这一环坏了会怎样」。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
WLAN="${WLAN:-wlan0}"
SSID="${SSID:-FLMap3}"
PASS="${PASS:-flmap2026}"
DOG_WIFI="${DOG_WIFI:-10.42.0.18}"
DOG_WIRE="${DOG_WIRE:-192.168.123.18}"
HOST=""
FIX=0

for a in "$@"; do
    case "$a" in
        --host=*) HOST="${a#*=}" ;;
        --fix)    FIX=1 ;;
        --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$a"; exit 2 ;;
    esac
done

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
sec() { printf '\n%s── %s%s\n' "$B" "$1" "$N"; }
ok()  { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
bad() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
dim() { printf '     %s%s%s\n' "$D" "$1" "$N"; }

# ---------------------------------------------------- 选地址
if [ -z "$HOST" ]; then
    for c in "$DOG_WIFI" "$DOG_WIRE"; do
        if ping -c1 -W1 "$c" >/dev/null 2>&1; then HOST="$c"; break; fi
    done
fi
if [ -z "$HOST" ]; then
    bad "两个地址都不通：$DOG_WIFI（无线）/ $DOG_WIRE（有线）"
    dim "无线没连上、网线也没插 —— 先用网线把 PC(enp131s0) 和狗(eth0) 连起来"
    dim "PC 侧有线地址会自动拿到 192.168.123.10（go2-wired profile）"
    exit 20
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "unitree@$HOST")
printf '%s\n' "============================================================"
printf ' 狗端无线诊断   %s   host=%s\n' "$(date '+%F %T')" "$HOST"
printf '%s\n' "============================================================"
[ "$HOST" = "$DOG_WIFI" ] && ok "走无线连上了狗（说明无线链路本来就是通的）" \
                          || warn "走有线连狗（$HOST）—— 诊断结论对无线同样成立"

# --fix：把「开机时热点还没起 → NM 重试 4 次后彻底放弃」这条最常见的坑先堵上
if [ "$FIX" -eq 1 ]; then
    sec "0. 先做可自动修的几项（--fix）"
    timeout 60 "${SSH[@]}" "sudo -n rfkill unblock all 2>/dev/null; \
        sudo -n nmcli device set $WLAN managed yes 2>/dev/null; \
        sudo -n nmcli connection modify flmap-wifi connection.autoconnect yes \
            connection.autoconnect-retries 0 2>/dev/null; \
        echo \"autoconnect-retries -> \$(sudo -n nmcli -g connection.autoconnect-retries connection show flmap-wifi 2>/dev/null)\"" \
        2>&1 | grep -v -i "warning: perm" | sed 's/^/     /'
    dim "retries=0 表示无限重试（默认 4 次，狗比热点先起来就再也连不回去了）"
fi

OUT=$(timeout 90 "${SSH[@]}" "WLAN='$WLAN' SSID='$SSID' bash -s" <<'EOS' 2>&1
set -u
say() { echo "@@$1"; }

say "uptime $(cut -d. -f1 /proc/uptime) $(date '+%F %T')"
say "kernel $(uname -r)"

# 1. 网卡是否被枚举（重启后 USB 掉枚举是最常见的一种）
if lsusb 2>/dev/null | grep -qiE "7612|0e8d"; then
    say "usb $(lsusb | grep -iE '7612|0e8d' | head -1)"
else
    say "usb MISSING"
fi

# 2. 驱动
say "mod $(lsmod 2>/dev/null | grep -E '^mt76' | awk '{print $1}' | tr '\n' ' ')"

# 3. 接口
if [ -e "/sys/class/net/$WLAN" ]; then
    say "iface $(cat /sys/class/net/$WLAN/operstate 2>/dev/null)"
    say "wireless $( [ -e "/sys/class/net/$WLAN/wireless" ] && echo yes || echo no)"
else
    say "iface MISSING"
fi

# 4. rfkill
say "rfkill $(rfkill list 2>/dev/null | grep -c Blocked || echo 0) blocked-line"
rfkill list 2>/dev/null | sed -n '1,8p' | sed 's/^/RFK /'

# 5. 当前 iw 状态
say "iw $(iw dev $WLAN info 2>/dev/null | awk '/type/{print $2}') $(iw dev $WLAN link 2>/dev/null | awk '/SSID/{print $2}')"

# 6. NM 托管
say "nmcli $(nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null | grep "^$WLAN" )"

# 7. profile 关键字段
say "prof $(nmcli -f 802-11-wireless.ssid,802-11-wireless.band,802-11-wireless.channel,connection.autoconnect,ipv4.method connection show flmap-wifi 2>/dev/null | tr '\n' ' ')"

# 8. 扫描 5 次，看 SSID 是否出现
hit=0
for i in 1 2 3 4 5; do
    sudo -n nmcli device wifi rescan ifname "$WLAN" 2>/dev/null
    sleep 4
    line=$(sudo -n nmcli -t -f SSID,SIGNAL,FREQ device wifi list ifname "$WLAN" 2>/dev/null | grep -F "$SSID" | head -1)
    if [ -n "$line" ]; then hit=1; say "scan HIT $line (第${i}次)"; break; fi
    say "scan miss $i"
done
if [ "$hit" -eq 0 ]; then
    n5=$(sudo -n iw dev $WLAN scan 2>/dev/null | grep -c 'freq: 5' || true)
    say "scan 5Gcount ${n5:-0}"
fi
EOS
)

# ---------------------------------------------------- 解析输出
sec "1. 狗端基础状态"
UP=$(printf '%s\n' "$OUT" | awk '/^@@uptime/{print $2}')
KER=$(printf '%s\n' "$OUT" | awk '/^@@kernel/{print $2}')
[ -n "${UP:-}" ] && dim "开机 ${UP:-?} 秒（$(awk -v u="${UP:-0}" 'BEGIN{printf "%.1f", u/60}') 分钟）  内核 $KER"

USB=$(printf '%s\n' "$OUT" | sed -n 's/^@@usb //p')
MOD=$(printf '%s\n' "$OUT" | sed -n 's/^@@mod //p')
IFACE=$(printf '%s\n' "$OUT" | sed -n 's/^@@iface //p')

if [ "$USB" = "MISSING" ]; then
    bad "USB 上找不到 MT7612U —— 重启后网卡没枚举"
    dim "狗身 USB 口松了/供电不足，重新插一次；插好后再跑本脚本"
    VERDICT="usb"
elif [ -z "${MOD:-}" ]; then
    bad "mt76 驱动没加载"
    dim "sudo modprobe mt76x2u；仍失败看 dmesg | grep -i mt76"
    VERDICT="mod"
elif [ "$IFACE" = "MISSING" ]; then
    bad "没有 $WLAN 接口"
    VERDICT="iface"
else
    ok "网卡枚举正常，驱动 ${MOD}，接口 $WLAN（${IFACE}）"
    VERDICT=""
fi

sec "2. 是否被软/硬阻塞"
RFK=$(printf '%s\n' "$OUT" | awk '/^@@rfkill/{print $2}')
printf '%s\n' "$OUT" | sed -n 's/^RFK //p' | head -6 | sed 's/^/     /'
if [ "${RFK:-0}" -ge 1 ]; then
    bad "有 rfkill block —— 无线被禁用，NM 永远连不上"
    dim "sudo rfkill unblock all && sudo nmcli device set $WLAN managed yes"
    VERDICT="${VERDICT:-rfkill}"
fi

sec "3. NetworkManager 托管与 profile"
NM=$(printf '%s\n' "$OUT" | sed -n 's/^@@nmcli //p')
PROF=$(printf '%s\n' "$OUT" | sed -n 's/^@@prof //p')
printf '     nmcli   %s\n' "${NM:-（读不到，NM 可能没跑）}"
printf '     profile %s\n' "${PROF:-（没有 flmap-wifi）}"
case "$NM" in
    *unmanaged*) bad "$WLAN 是 unmanaged —— NM 不会自动连接"
                 dim "sudo nmcli device set $WLAN managed yes"
                 VERDICT="${VERDICT:-unmanaged}" ;;
    *connected*) ok "$WLAN 已连接" ;;
    "")          bad "nmcli 读不到设备状态"
                 VERDICT="${VERDICT:-nmcli}" ;;
    *)           dim "当前未连接，但有 profile 就会自动重试" ;;
esac
printf '%s\n' "$PROF" | grep -q "FLMap3" && ok "profile 指向 $SSID" || { bad "profile 里 SSID 不是 $SSID"; VERDICT="${VERDICT:-prof}"; }

sec "4. 能否扫到 $SSID"
HITLN=$(printf '%s\n' "$OUT" | sed -n 's/^@@scan HIT //p' | head -1)
MISS=$(printf '%s\n' "$OUT" | grep -c '^@@scan miss' || true)
N5=$(printf '%s\n' "$OUT" | sed -n 's/^@@scan 5Gcount //p')
if [ -n "$HITLN" ]; then
    ok "扫到了：$HITLN"
    SCAN_OK=1
else
    SCAN_OK=0
    bad "扫了 ${MISS:-5} 次都没看到 $SSID"
    [ -n "${N5:-}" ] && dim "狗端本次 5G 频点条目 ${N5} 个（>0 说明 5G 接收正常，问题在热点侧）"
    dim "含义：热点在该信道上没有发出能被狗端收到的 beacon"
    VERDICT="${VERDICT:-ap_silent}"
fi

# ---------------------------------------------------- 能扫到就尝试连
if [ "$SCAN_OK" -eq 1 ]; then
    sec "5. 尝试关联"
    OUT2=$(timeout 60 "${SSH[@]}" "sudo -n nmcli connection up flmap-wifi 2>&1 | tail -3" 2>&1 | grep -v -i "warning: perm")
    printf '%s\n' "$OUT2" | sed 's/^/     /'
    sleep 2
    L=$(timeout 20 "${SSH[@]}" "iw dev $WLAN link 2>/dev/null | head -4; ip -4 -o addr show dev $WLAN | awk '{print \"ADDR=\" \$4}'" 2>&1 | grep -v -i "warning: perm")
    printf '%s\n' "$L" | sed 's/^/     /'
    if printf '%s\n' "$L" | grep -q "ADDR="; then
        ok "已拿到地址，无线通了"
        VERDICT="ok"
    else
        bad "关联失败或没拿到地址"
        VERDICT="${VERDICT:-assoc}"
    fi
fi

# ---------------------------------------------------- 结论
sec "结论"
case "${VERDICT:-ok}" in
    ok)
        printf '  %s无线链路正常%s —— 以后重启不用插网线。\n' "$G" "$N"
        printf '  接着建图： ssh -t unitree@%s '"'"'bash ~/flmap3_ws/scripts/edge_control.sh'"'"'\n' "$DOG_WIFI" ;;
    usb)
        printf '  %s网卡掉枚举%s —— 这是硬件层，不是配置。重插 USB 无线网卡后重跑。\n' "$R" "$N"
        printf '  若每次重启都掉，加一个开机延迟加载：\n'
        printf '    echo "options mt76x2u" | sudo tee /etc/modprobe.d/mt76x2u.conf\n' ;;
    ap_silent)
        printf '  %s扫描看不到 AP%s —— 两种可能，用手机一秒分清：\n' "$Y" "$N"
        printf '    · 手机也搜不到 FLMap3 → 热点静默，按下面在 PC 上处置\n'
        printf '    · 手机能搜到并连上   → 热点没问题，是狗端放弃重试了\n'
        printf '      插网线跑 ./scripts/dog_wifi_diag.sh --fix（把 retries 改成 0）\n\n'
        printf '  热点侧处置：\n
        printf '  在 PC 上依次试：\n'
        printf '    sudo ./scripts/ap_watchdog.sh --once        # 体检，看 AP 是否静默\n'
        printf '    sudo ./scripts/pc_hotspot.sh --reload       # 重载 rtw89（固件队列卡死）\n'
        printf '    sudo ./scripts/ap_chan_probe.sh             # 换信道确认\n'
        printf '  另可用手机搜一次 FLMap3：手机也搜不到 = 确认热点侧问题。\n' ;;
    rfkill)    printf '  %s无线被 rfkill 禁用%s，unblock 后重跑。\n' "$R" "$N" ;;
    unmanaged) printf '  %sNM 不托管 %s%s，`nmcli device set %s managed yes` 后重跑。\n' "$R" "$WLAN" "$N" "$WLAN" ;;
    assoc)     printf '  %s扫得到但连不上%s，多半是密码/认证。\n' "$Y" "$N"
               printf '  看狗端： journalctl -u NetworkManager -n 40 | grep -iE "deauth|auth|psk|key"\n'
               printf '  然后 ./scripts/dog_wifi_diag.sh --fix 把重试次数改成无限\n' ;;
    *)         printf '  %s（诊断未得出结论，把上面整段输出发我）%s\n' "$Y" "$N" ;;
esac
printf '\n'
