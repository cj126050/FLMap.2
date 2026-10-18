#!/usr/bin/env bash
# =============================================================
#  wifi_scan_report.sh —— 判定「机器狗热点到底在不在广播」
#
#  背景
#  ----
#  Unitree Go2 改过 WiFi 名称后，手机和 PC 都可能搜不到。三种可能：
#    ① 名字没生效，还在广播出厂名（Go2_xxxxxx）
#    ② 被设成了隐藏网络（SSID 不广播）
#    ③ AP 根本没起来
#  三者处置完全不同，但这个脚本能把它们分开。
#
#  为什么需要 sudo：扫描要发 probe request，普通用户没有 NET_ADMIN。
#  所以必须在**你自己的终端**里跑，不能在受限的自动化环境里跑。
#
#  用法
#    sudo ./scripts/wifi_scan_report.sh                    # 全量扫描并判定
#    sudo ./scripts/wifi_scan_report.sh 13829973977        # 顺便尝试连这个隐藏名
#
#  NO_OUI_LOOKUP=1 可跳过 MAC 厂商查询（离线/不想联网时用）
#
#  只读 + 可选连接，不改任何已有网络配置（连不上会自动回滚到原来的网络）。
# =============================================================
set -uo pipefail

TARGET_SSID="${1:-}"
IFACE="${WIFI_IFACE:-$(iw dev 2>/dev/null | sed -n 's/^[[:space:]]*Interface \([^ ]*\)/\1/p' | head -1)}"
PASS="${WIFI_PASS:-}"

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
sec() { printf '\n%s── %s %s\n' "$c_b" "$1" "$c_0"; }
ok()  { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }

if [ "$(id -u)" != "0" ]; then
    bad "需要 root，请用： sudo $0 $*"
    exit 1
fi
if [ -z "$IFACE" ]; then
    bad "找不到无线接口"
    exit 1
fi

echo "============================================================"
echo " 无线扫描判定   接口 $IFACE   $(date '+%F %T')"
echo "============================================================"

# ---------------------------------------------------------------- 1. 触发重扫
sec "1. 触发重扫（不断开当前连接）"
CUR_SSID=$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
[ -n "$CUR_SSID" ] && printf '  当前连接: %s\n' "$CUR_SSID"
nmcli device wifi rescan 2>/dev/null || true
sleep 5
ok "已请求重扫"

# 只有明确要求时才重置射频——那会短暂断网，可能把自己也断掉
if [ "${DO_RESET:-0}" = "1" ]; then
    warn "执行射频重置（会短暂断网）"
    nmcli radio wifi off 2>/dev/null; sleep 3; nmcli radio wifi on 2>/dev/null; sleep 5
fi

# ---------------------------------------------------------------- 2. 全量扫描
sec "2. 全量扫描（含隐藏网络）"
SCAN=$(iw dev "$IFACE" scan 2>/dev/null)
if [ -z "$SCAN" ]; then
    bad "扫描失败或还没扫到任何 AP。请重跑，或确认网卡没被占用"
    exit 1
fi

# 解析成 "信号 dBm | 频率 | BSSID | SSID" 形式
# 注意：iw 的 BSS 行是 "BSS 24:4b:fe:0a:ce:14(on wlp132s0)"，MAC 后面粘着 "(on ..."
printf '%s\n' "$SCAN" | awk '
    function flush() {
        if (have) printf "%s\t%s\t%s\t%s\n", sig, freq, mac, ssid
    }
    /^BSS / {
        flush()                       # 先输出上一条，再重置
        mac = $2; sub(/\(.*/, "", mac)
        sig = "?"; freq = "?"; ssid = "<隐藏或空>"; have = 1
        next
    }
    /signal:/       { sig = $2 }
    /^[ \t]*freq:/  { freq = $2 }
    /SSID:/         { sub(/^[ \t]*SSID:[ \t]*/, ""); ssid = ($0 == "" ? "<隐藏或空>" : $0) }
    END { flush() }
' | awk -F'\t' '$1 != "?"' | sort -k1,1nr > /tmp/wifi_scan.$$ 2>/dev/null

TOTAL=$(wc -l < /tmp/wifi_scan.$$)
printf '  扫到 %s 个 AP\n\n' "$TOTAL"
printf '  %-8s %-8s %-19s %s\n' "信号" "频率" "BSSID" "SSID"
printf '  %-8s %-8s %-19s %s\n' "------" "------" "-----------------" "-----------------------------"
awk -F'\t' '{ printf "  %-8s %-8s %-19s %s\n", $1, $2, $3, $4 }' /tmp/wifi_scan.$$ | head -40

# ---------------------------------------------------------------- 3. 判定
sec "3. 判定"

# ③-前置：剔掉「全零 SSID」伪条目。很多路由在探测响应里塞 0x00 填充，
# 看起来像"隐藏网络"，其实不是——不剔掉会把人往情况②带偏。
CLEAN=/tmp/wifi_scan_clean.$$
ZEROED=$(awk -F'\t' 'index($4,"\\x00")>0' /tmp/wifi_scan.$$ | wc -l)
awk -F'\t' 'index($4,"\\x00")>0 {next} {print}' /tmp/wifi_scan.$$ > "$CLEAN"

# 用 MAC 前缀查厂商，避免把邻居家的隐藏路由误当成机器狗。
# 关掉：NO_OUI_LOOKUP=1 sudo ./scripts/wifi_scan_report.sh
oui_vendor() {
    [ -n "${NO_OUI_LOOKUP:-}" ] && { echo "?"; return; }
    local v
    v=$(curl -s --max-time 2 "https://api.macvendors.com/${1:0:8}" 2>/dev/null) || v=""
    case "$v" in
        ""|*"not found"*|*"rate limit"*|*"{"*) echo "?" ;;
        *) echo "$v" ;;
    esac
}

# 疑似机器狗：出厂名、Unitree 字样、或纯 11 位数字（很多人把手机号当热点名）
HIT_NAME=$(awk -F'\t' 'tolower($4) ~ /go2|unitree/ || $4 ~ /^[0-9]{11}$/' "$CLEAN" | head -3)
HIDDEN=$(awk -F'\t' '$4=="<隐藏或空>" || $4==""' "$CLEAN")
STRONG=$(awk -F'\t' '$1+0 >= -55' "$CLEAN" | head -5)

if [ -n "$HIT_NAME" ]; then
    ok "扫到疑似机器狗的网络："
    printf '%s\n' "$HIT_NAME" | awk -F'\t' '{ printf "      %s dBm  %s MHz  %s\n", $1, $2, $4 }'
    printf '    → 情况①：名字没生效或你找的不是这个。连它即可。\n'
elif [ -n "$HIDDEN" ]; then
    warn "扫到不广播 SSID 的网络，逐条过三道筛："
    SUSPECT=0
    while IFS=$'\t' read -r sig freq bssid ssid; do
        [ -z "${bssid:-}" ] && continue
        sigr=$(printf '%.0f' "$sig" 2>/dev/null || echo 0)
        o1="${bssid%%:*}"
        la=0
        [[ "$o1" =~ ^[0-9A-Fa-f]{2}$ ]] && [ $(( 16#$o1 & 2 )) -ne 0 ] && la=1

        note=""; cand=1
        if [ "$sigr" -lt -70 ]; then
            note="信号 ${sigr} dBm 太弱（1 m 内应 ≥ −50）"; cand=0
        elif [ "$la" -eq 1 ]; then
            # 实测：Go2 自己的热点就是 7a:22:88:af:9d:29（本地管理地址）。
            # 所以 LA 位只能说明"不是厂商 OUI"，**不能**用来排除机器狗。
            note="本地管理地址（Go2 热点自身也用这种，不能据此排除）"; v="—"
        else
            v=$(oui_vendor "$bssid")
            case "$v" in
                *TP-LINK*|*Hewlett*|*XIAOMI*|*Xiaomi*|*HUAWEI*|*H3C*|*Tenda*|*Ruijie*|*D-Link*|*ASUSTek*|*ZTE*|*Mercury*|*Netcore*|*Netis*|*Shenzhen*) cand=0 ;;
            esac
        fi

        printf '      %s dBm  %s MHz  %s   [%s]%s\n' "$sig" "$freq" "$bssid" "$v" "${note:+  ← $note}"
        [ "$cand" -eq 1 ] && SUSPECT=$((SUSPECT+1))
    done <<< "$HIDDEN"

    if [ "$SUSPECT" -eq 0 ]; then
        bad "全部排除：家用路由品牌 / 虚拟 BSSID / 信号过弱，没有一条像机器狗"
        printf '    → 情况③：AP 根本没有广播。别再去"添加隐藏网络"里试了。\n'
        printf '       狗在 AP 模式开机约 1–2 分钟必然广播一次；长时间不见就是没起来。\n'
    else
        warn "有 $SUSPECT 个仍可能是狗的隐藏网络（近、且认不出牌子）："
        printf '    → 对照狗底部/电池仓贴纸上的 MAC 前缀，对得上就是情况②。\n'
        printf '    → 对不上就是情况③（AP 没起来）。\n'
    fi
elif [ -n "$STRONG" ]; then
    warn "附近有强信号 AP，但没有隐藏 SSID 的条目："
    printf '%s\n' "$STRONG" | awk -F'\t' '{ printf "      %s dBm  %s MHz  %s\n", $1, $2, $4 }'
    printf '    → 情况③：AP 没有在广播。\n'
else
    bad "没有任何强信号 AP，也没有隐藏条目"
    printf '    → 情况③：AP 没起来。检查是否通电足够久、是否被切成中继(STA)模式。\n'
fi

[ "$ZEROED" -gt 0 ] && printf '  （已忽略 %s 条全零 SSID 的伪隐藏条目，这是路由的探测响应填充，不是隐藏网络）\n' "$ZEROED"
rm -f "$CLEAN"

# ---------------------------------------------------------------- 4. 隐藏名直连
if [ -n "$TARGET_SSID" ]; then
    sec "4. 尝试直连隐藏网络 \"$TARGET_SSID\""
    if [ -z "$PASS" ]; then
        warn "没给密码。用法： sudo WIFI_PASS='你的密码' $0 $TARGET_SSID"
    else
        # 记住原来的连接，失败时回滚
        ORIG_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
                    | awk -F: -v d="$IFACE" '$2==d{print $1}' | head -1)
        printf '  原连接: %s\n' "${ORIG_CONN:-无}"
        if nmcli device wifi connect "$TARGET_SSID" password "$PASS" hidden yes \
             ifname "$IFACE" 2>&1 | sed 's/^/    /'; then
            ok "连上了！说明就是隐藏网络（情况②）"
        else
            bad "连不上。可能密码不对，或该 SSID 确实不存在（情况③）"
            if [ -n "$ORIG_CONN" ]; then
                printf '  正在回滚到 %s ...\n' "$ORIG_CONN"
                nmcli connection up "$ORIG_CONN" >/dev/null 2>&1 && ok "已回滚" || warn "回滚失败，请手动重连"
            fi
        fi
    fi
fi

rm -f /tmp/wifi_scan.$$
echo
echo "============================================================"
