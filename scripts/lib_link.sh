#!/bin/bash
# =============================================================
#  lib_link.sh —— 链路层（FLMap.2 · 无线包）
#
#  拓扑：PC 无线网卡作 AP 10.42.0.1/24 ══ 5 GHz ══ 狗端 USB 网卡 wlan0 10.42.0.18/24
#                                               └─ 狗 eth0 192.168.123.18（雷达/运控段，不出这个口）
#
#  这个文件是本包里**唯一知道"链路长什么样"的地方**。
#
#  为什么要单独抽出来
#  -------------------
#  目标地址原来散在 6 个脚本里，每个脚本自己 `for h in 10.42.0.18 192.168.123.18; do ping`
#  于是热点刚重建时（nmcli 先 down 再 up，狗要重连 10–30 秒）每次都误判成有线模式，
#  对着一堆不存在的 123 地址报"丢包 100%""协商速率 -1 Mbit/s"，七条红叉全是假的。
#
#  判据不是"谁 ping 得通"，而是"本机是不是热点"。
#
#  现在的规矩
#  ----------
#    · 任何脚本都不许写死 IP、不许自己 ping 试探目标；一律 source 本文件。
#    · 有线包是 FLMap.3，它的同名文件负责有线链路；两个文件的**函数接口完全一致**，
#      所以 link_probe / pc_view / edge_scan / edge_control 可以是同一份代码。
#    · 本文件不许出现 192.168.123.x 作为"本机该有的地址" —— 那是狗端内部网段。
#
#  用法
#  ----
#    source "$REPO_DIR/scripts/lib_link.sh"
#    EDGE_HOST=$(link_resolve 10)      # 参数是"最多等几秒让狗重连"
# =============================================================

LINK_KIND="wireless"
LINK_DESC="无线 10.42.0.0/24（主机作 AP，狗端 USB 网卡作 STA）"
LINK_DEFAULT_HOST="10.42.0.18"
LINK_LOCAL_PREFIX="10.42.0."
LINK_PC_ADDR="10.42.0.1/24"
LINK_IFACE_PAT="wl*"
LINK_EDGE_WS="${EDGE_WS:-~/flmap_ws}"

# 本机的热点地址（10.42.0.x）
link_local_addr() {
    ip -o -4 addr show 2>/dev/null |
        awk -v p="$LINK_LOCAL_PREFIX" '$4 ~ "^"p {sub(/\/.*/, "", $4); print $2 " " $4; exit}'
}

# 等某台主机上线
link_wait_host() {
    local host="$1" secs="${2:-0}" i
    [ "$secs" -gt 0 ] || return 1
    for ((i = 1; i <= secs; i++)); do
        ping -c1 -W1 "$host" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# 解析目标地址；参数是等待秒数（只在热点模式下等，绝不以"ping 不通"为由换目标）
link_resolve() {
    local wait="${1:-0}"
    if [ -n "${EDGE_HOST:-}" ]; then          # 用户显式指定，最高优先，不做任何猜测
        printf '%s\n' "$EDGE_HOST"
        return 0
    fi
    if [ -n "$(link_local_addr)" ]; then      # 本机就是热点：目标唯一，等着但绝不换
        link_wait_host "$LINK_DEFAULT_HOST" "$wait" >/dev/null 2>&1
        printf '%s\n' "$LINK_DEFAULT_HOST"
        return 0
    fi
    # 连热点地址都没有：热点没起来。如实报无线目标，别静默切到有线 ——
    # 那样只会把"热点没开"伪装成"狗没开机 / 网线没插"。
    printf '%s\n' "$LINK_DEFAULT_HOST"
}

# 第 1 节前半：本机是否具备热点地址
link_check_local() {
    LOCAL_ADDR="$(link_local_addr)"
    if [ -n "$LOCAL_ADDR" ]; then
        pass "本机热点地址 ${LOCAL_ADDR}"
        return 0
    fi
    fail "本机没有 ${LINK_LOCAL_PREFIX}x 地址 —— 热点没起来"
    echo "     起热点： sudo ./scripts/pc_hotspot.sh"
    echo "     看网卡： iw dev | grep -i interface   ./scripts/dog_wlan_probe.sh 在狗端查网卡"
    echo "     想走有线：用 FLMap.3（有线包），不要在本包里绕"
    return 1
}

# 第 1 节后半：出口网卡是否符合预期
link_check_iface() {
    local iface="${1:-}" itype clients sig txb ssid freq
    case "$iface" in
        "")
            fail "没有到 ${EDGE_HOST} 的路由 —— 热点没起，或狗还没连上"
            return 1
            ;;
        wl*)
            pass "走无线口 ${iface}（预期）"
            # PC 是 AP、狗是 STA：`iw link` 在 AP 模式下恒为 "Not connected"，
            # 拿它判链路会永远误报。必须按接口类型分开看。
            itype=$(iw dev "$iface" info 2>/dev/null | sed -n 's/.*type \([A-Za-z]*\).*/\1/p')
            if [ "$itype" = "AP" ]; then
                clients=$(iw dev "$iface" station dump 2>/dev/null | grep -c '^Station')
                if [ "${clients:-0}" -eq 0 ]; then
                    fail "主机是 AP 模式，但当前没有客户端接入 —— 狗端 wlan0 掉线了"
                    echo "     狗端重连： sudo ./scripts/dog_wlan_join.sh（在狗上跑）"
                    return 1
                fi
                pass "主机是 AP 模式，已接入 ${clients} 个客户端"
                # 每个客户端的信号强度就是狗端的实际信号
                iw dev "$iface" station dump 2>/dev/null |
                    awk '/^Station/{mac=$2} /signal:/{printf "    客户端 %s 信号 %s dBm\n", mac, $2}' | head -3
            else
                local wl
                wl=$(iw dev "$iface" link 2>/dev/null)
                if [ -z "$wl" ] || echo "$wl" | grep -q "Not connected"; then
                    fail "${iface} 未关联任何 AP —— 检查主机热点是否起来（scripts/pc_hotspot.sh）"
                    return 1
                fi
                sig=$(echo "$wl" | sed -n 's/.*signal: \(-\?[0-9]*\) dBm.*/\1/p')
                txb=$(echo "$wl" | sed -n 's/.*tx bitrate: \([0-9.]*\) MBit.*/\1/p')
                ssid=$(echo "$wl" | sed -n 's/^SSID: //p')
                freq=$(echo "$wl" | sed -n 's/.*freq: \([0-9]*\).*/\1/p')
                echo "  SSID ${ssid:-?}  ${freq:-?} MHz  信号 ${sig:-?} dBm  tx ${txb:-?} Mbit/s"
                if [ -z "$sig" ]; then
                    warn "读不到信号强度（驱动没暴露）—— 只能靠下面的丢包/抖动判断"
                elif [ "$sig" -ge -65 ]; then
                    pass "信号强度够（≥ -65 dBm）"
                elif [ "$sig" -ge -72 ]; then
                    warn "信号 ${sig} dBm 偏低 —— 点云会间歇卡顿；把网卡天线挪到狗背开口处"
                else
                    fail "信号 ${sig} dBm 太弱 —— 先解决距离/遮挡（狗身金属壳等于屏蔽罩）"
                    return 1
                fi
                if [ -n "$txb" ] && awk -v b="$txb" 'BEGIN{exit !(b<60)}'; then
                    warn "协商速率只有 ${txb} Mbit/s —— 低于 60 会顶不住 10 Hz 点云"
                fi
            fi
            ;;
        en*|eth*)
            fail "走的是有线口 ${iface} —— 目标在无线网段 10.42.0.0/24，不该从有线口出去"
            echo "     多半是残留的 192.168.123.x 配置在抢路由： ip route get ${EDGE_HOST}"
            echo "     清理： sudo nmcli connection delete <那条有线连接>"
            return 1
            ;;
        *)
            warn "走的是 ${iface}，不是预期的网卡名（wl*）"
            ;;
    esac
    return 0
}

# ping 不通时的排查顺序
link_check_hints() {
    echo -e "\n${Y:-}排查顺序${N:-}:"
    [ -z "${LOCAL_ADDR:-}" ] && echo "  0) 【本次根因】热点没起来 —— 见上面 §1"
    echo "  1) 狗上电了吗？热点重建后（每次 pc_hotspot.sh 都会）狗要重连 10–30 秒"
    echo "     看主机 AP 有没有客户端接入： iw dev wl* station dump | grep -c ^Station"
    echo "  2) 热点还在吗？ nmcli connection show --active | grep hotspot"
    echo "  3) 狗端 wlan0 还连着吗？ ssh ${EDGE_USER:-unitree}@${LINK_DEFAULT_HOST} 'iw dev wlan0 link'"
    echo "  4) 狗端会不会掉回旧 AP 了？新网卡连上后要设 autoconnect 优先"
}

# 可视化脚本用的三行短提示（pc_view.sh）
link_ping_hint() {
    echo "  - 热点起来了吗？ iw dev | grep -i interface，或 sudo ./scripts/pc_hotspot.sh"
    echo "  - 狗端 wlan0 连上了吗？ iw dev wl* station dump | grep -c ^Station"
    echo "  - 想继续启动（比如换 EDGE_HOST）按 Ctrl-C 退出"
}

# 第 4 节：DDS 多播出口
link_check_multicast() {
    local dd_if="${1:-}" exp_if="${2:-}"
    [ -z "$dd_if" ] && return 0
    if [ -n "$exp_if" ] && [ "$dd_if" != "$exp_if" ]; then
        warn "DDS 多播出口是 ${dd_if}，不是 ${exp_if} —— 主机发的发现包会从错误网卡出去"
        echo "     修： sudo ip route add 239.255.0.1/32 dev ${exp_if}   （pc_hotspot.sh 已内置）"
    else
        echo "  DDS 多播出口: ${dd_if}"
    fi
    return 0
}

# 时延阈值：回显 "平均RTT上限 抖动上限"
link_latency_limits() {
    echo "10 5"
}

# 第 5 节带宽参考值
link_bandwidth_note() {
    echo "  /flmap/cloud 带宽 ≈ $1（原始≈1.5 MB/s；无线实测 1.4–1.5 MB/s，占 173 Mbit/s 的 7%）"
}

# PC 在本链路里的地址（狗端 link 命令测 RTT 用）
link_pc_addr() {
    printf '%s\n' "${FLMAP_PC_IP:-10.42.0.1}"
}

# ping 不通时给狗端 link 命令用的一句话
LINK_HINT_PC="热点是否还在、狗端 wlan0 是否掉线"

# 狗端 link 命令用：列出链路相关网口（有线段 + 无线段）
link_report_ifaces() {
    local found=0 d n carrier speed addr wfound wl sig txb

    echo -e "${C:-}--- 有线网口（雷达/运控段，不出这个口）---${N:-}"
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        case "$n" in lo|wl*|docker*|veth*|dummy*|br-*|can*|usb*) continue ;; esac
        [ -e "$d/device" ] || continue
        found=1
        carrier=$(cat "$d/carrier" 2>/dev/null)
        speed=$(cat "$d/speed" 2>/dev/null)
        addr=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}')
        printf "  %-8s %-20s carrier=%s  speed=%sMb/s\n" \
            "$n" "${addr:-无地址}" "${carrier:-?}" "${speed:-?}"
    done
    [ "$found" = "0" ] && echo "  没有找到有线网口"

    # 无线才是本包的主链路，必须一起看：signal 掉到 -70 以下点云就开始丢帧
    echo -e "${C:-}--- 无线网口 ---${N:-}"
    wfound=0
    for d in /sys/class/net/wl*; do
        [ -e "$d" ] || continue
        wfound=1
        n=$(basename "$d")
        addr=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}')
        # PC 上是 AP 模式：`iw link` 恒为 Not connected，要改看已接入的客户端
        if [ "$(iw dev "$n" info 2>/dev/null | sed -n 's/.*type \([A-Za-z]*\).*/\1/p')" = "AP" ]; then
            sig=$(iw dev "$n" station dump 2>/dev/null |
                  awk '/^Station/{m=$2} /signal:/{printf "%s:%s ", m, $2}' | head -c 120)
            printf "  %-8s %-20s AP模式  客户端 %s 信号 %s\n" \
                "$n" "${addr:-无地址}" \
                "$(iw dev "$n" station dump 2>/dev/null | grep -c '^Station')" "${sig:-无}"
            continue
        fi
        wl=$(iw dev "$n" link 2>/dev/null)
        sig=$(echo "$wl" | sed -n 's/.*signal: \(-\?[0-9]*\) dBm.*/\1/p')
        txb=$(echo "$wl" | sed -n 's/.*tx bitrate: \([0-9.]*\) MBit.*/\1/p')
        printf "  %-8s %-20s signal=%s dBm  tx=%s Mb/s\n" \
            "$n" "${addr:-无地址}" "${sig:-未连接}" "${txb:-?}"
    done
    [ "$wfound" = "0" ] && echo "  没有无线网口"
    return 0
}
