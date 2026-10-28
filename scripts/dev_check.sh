#!/usr/bin/env bash
# =============================================================
#  dev_check.sh —— 一次查清三条链路
#
#   1. PC  <-> 狗      无线 10.42.0.18（主机作 AP）或 有线 192.168.123.18
#   2. 狗  <-> D435i   USB 3，必须挂在 5000M 链路上，否则只能出低分辨率
#   3. 狗  <-> MID360  以太网，雷达 IP 从 MID360_config.json 读，不写死
#
#  为什么 MID360 要读配置文件
#  --------------------------
#  出厂是 192.168.1.1xx，这个工程里已经改成 192.168.123.221，
#  和狗 eth0、PC 同在一个交换网段。写死任何一边，换了现场就会指错方向。
#
#  用法
#  ----
#    ./scripts/dev_check.sh              # 三条全查
#    ./scripts/dev_check.sh --link       # 只查 PC<->狗
#    ./scripts/dev_check.sh --dev        # 链路已通，只查狗上的两个设备
# =============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_link.sh
. "${REPO_DIR}/scripts/lib_link.sh"

EDGE_USER="${EDGE_USER:-unitree}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
MODE="${1:-all}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
dim()  { printf '    \033[2m%s\033[0m\n' "$*"; }
sec()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# ─────────────────────── 1. PC <-> 狗 ───────────────────────
sec "1. PC ←→ 狗"

WLAN_IF=$(ip -br addr 2>/dev/null | awk '/^w/{print $1; exit}')
WLAN_ADDR=$(ip -br addr show "${WLAN_IF:-none}" 2>/dev/null | awk '{print $3}')
AP_UP=0
for _a in "${WLAN_ADDR:-}" $(ip -br addr 2>/dev/null | awk '{print $3}'); do
    case "$_a" in ${LINK_LOCAL_PREFIX}*) AP_UP=1 ;; esac
done

if [ "$AP_UP" = "1" ]; then
    ok "主机热点已开（${LINK_PC_ADDR}）"
else
    bad "主机没有 ${LINK_LOCAL_PREFIX}x 地址 —— 热点没开，狗无处可连"
    if [ -n "$WLAN_IF" ]; then
        CUR=$(iw dev "$WLAN_IF" link 2>/dev/null | awk '/^Connected/{f=1} f&&/SSID/{print $2; exit}')
        [ -n "$CUR" ] && dim "当前 ${WLAN_IF} 是 STA 模式，连着 ${CUR} —— 开热点会踢掉它"
    fi
    dim "开热点： sudo ./scripts/pc_hotspot.sh"
fi

DEF_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
# 排除 enx*（USB 网卡，比如手机 RNDIS）和默认路由口，否则会把手机共享网络误报成"有线口通"
WIRED_IF=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(en|eth)' | grep -v '^enx' | while read -r n; do
    [ "$n" = "$DEF_IF" ] && continue
    [ "$(cat /sys/class/net/$n/carrier 2>/dev/null)" = "1" ] && echo "$n"
done | head -1)
if [ -n "$WIRED_IF" ]; then
    SP=$(cat /sys/class/net/"$WIRED_IF"/speed 2>/dev/null)
    [ "${SP:-0}" -gt 0 ] 2>/dev/null || SP="?"
    ok "有线口 ${WIRED_IF} 链路通（${SP} Mbit/s）"
else
    warn "没有可用的有线口（排除手机 USB 网卡后）—— 网线没插，或对端没上电"
    for n in $(ls /sys/class/net/ 2>/dev/null | grep -E '^(en|eth)' | grep -v '^enx'); do
        dim "$n: $(cat /sys/class/net/$n/operstate 2>/dev/null) carrier=$(cat /sys/class/net/$n/carrier 2>/dev/null)"
    done
fi

if [ "$MODE" != "--dev" ]; then
    # link_resolve 只回配置里的固定地址，不主动探测，所以下面自己 ping 验证
    EDGE_HOST=$(link_resolve 0 2>/dev/null)
    if [ -z "${EDGE_HOST:-}" ]; then
        bad "解析不到狗地址（链路 ${LINK_DESC}）"
        echo
        echo "  先解决链路，再查设备。两条路选一条："
        echo "    无线： sudo ./scripts/pc_hotspot.sh     （开热点，狗开机自连）"
        echo "    有线： 插网线到交换机，确认 PC 网卡配了 192.168.123.10"
        exit 2
    fi
    ok "狗 = ${EDGE_HOST}"
    if ping -c 3 -W 1 "$EDGE_HOST" >/dev/null 2>&1; then
        RTT_MS=$(ping -c 3 -W 1 "$EDGE_HOST" 2>/dev/null \
                 | awk -F'/' '/^rtt|^round-trip/{print $5}')
        RTT_MS="${RTT_MS:-0}"
        # 局域网应为个位数毫秒。几十毫秒 + TTL 掉得多 = 包出了公网，
        # 那个地址只是碰巧存在（蜂窝网里 10.42.x 撞号很常见），不是狗。
        if [ "${RTT_MS%%.*}" -gt 20 ] 2>/dev/null; then
            bad "ICMP 通但平均 ${RTT_MS} ms —— 这是跨公网的设备，不是本地狗"
            dim "真狗的局域网延迟应在 1~3 ms。别把它当狗去查，会连带 ssh 报错"
            exit 2
        fi
        ok "ICMP 通（${RTT_MS} ms）"
    else
        bad "ping 不通 ${EDGE_HOST}"
        link_check_hints 2>/dev/null || true
        exit 2
    fi
    if ssh "${SSH_OPTS[@]}" -i ~/.ssh/id_ed25519 -o BatchMode=yes \
           "${EDGE_USER}@${EDGE_HOST}" true 2>/dev/null; then
        ok "SSH 通"
    else
        bad "SSH 不通 —— 后面的设备检查做不了"
        dim "试： ssh ${EDGE_USER}@${EDGE_HOST}  （确认密钥或密码）"
        exit 2
    fi
fi

if [ "$MODE" = "--link" ]; then
    printf '\n\033[1m只查链路，结束\033[0m\n'
    exit 0
fi

# --dev 模式跳过了第 1 节，这里补一次地址解析
: "${EDGE_HOST:=$(link_resolve 0 2>/dev/null)}"
if [ -z "${EDGE_HOST:-}" ]; then
    bad "拿不到狗地址"
    exit 2
fi

# 后面两节都在狗上执行
DOG() { ssh "${SSH_OPTS[@]}" -i ~/.ssh/id_ed25519 -o BatchMode=yes "${EDGE_USER}@${EDGE_HOST}" "$@" 2>/dev/null; }

# ─────────────────────── 2. 狗 <-> D435i ───────────────────────
sec "2. 狗 ←→ D435i（USB）"

REMOTE_D435='
set -u
found=0
for d in /sys/bus/usb/devices/*/; do
    [ -r "$d/idVendor" ] || continue
    v=$(cat "$d/idVendor" 2>/dev/null)
    [ "$v" = "8086" ] || continue
    found=1
    p=$(cat "$d/idProduct" 2>/dev/null)
    sp=$(cat "$d/speed" 2>/dev/null)
    pr=$(cat "$d/product" 2>/dev/null)
    ifn=$(basename "$d")
    echo "USB|$ifn|$v:$p|$sp|${pr:-RealSense}"
done
[ "$found" = "0" ] && echo "USB|NONE||||"
# 视频节点
echo "VIDEO|$(ls /dev/video* 2>/dev/null | tr "\n" " ")"
# 内核是否认出 UVC 摄像头
echo "KMSG|$(dmesg 2>/dev/null | grep -ci "realsense\|8086" )"
# librealsense 命令行（装了才有）
if command -v rs-enumerate-devices >/dev/null 2>&1; then
    echo "RSENUM|$(rs-enumerate-devices -s 2>/dev/null | head -4 | tr "\n" ";")"
else
    echo "RSENUM|NOT_INSTALLED"
fi
echo "END"
'

D435_OUT=$(DOG "$REMOTE_D435")
if [ -z "$D435_OUT" ]; then
    bad "远程命令无返回，跳过"
else
    USB_LINE=$(echo "$D435_OUT" | grep "^USB|" | head -1)
    if echo "$USB_LINE" | grep -q "NONE"; then
        bad "狗上没有 Intel(8086) USB 设备 —— D435i 没插好，或插在不供电的口"
        dim "线换一个 USB3 口再试；D435i 对电流敏感，别用无源 HUB"
    else
        IFS='|' read -r _ dev id spd prod <<< "$USB_LINE"
        ok "识别到 ${prod}  ${id}  设备号 ${dev}"
        case "$spd" in
            5000|10000) ok "USB 链路 ${spd} Mbit/s（USB3 正常）" ;;
            480) bad "USB 链路只有 480 Mbit/s（USB2）—— 带宽不够，深度会掉帧"
                 dim "多半是线材只是充电线，或插在 USB2 口 / 无源 HUB 上" ;;
            *)   warn "USB 链路速度=${spd:-未知}" ;;
        esac
    fi
    VD=$(echo "$D435_OUT" | sed -n 's/^VIDEO|//p')
    if [ -n "$VD" ]; then ok "视频节点：${VD}"; else warn "没有 /dev/video* （驱动没绑上）"; fi
    RS=$(echo "$D435_OUT" | sed -n 's/^RSENUM|//p')
    case "$RS" in
        NOT_INSTALLED) warn "狗上没装 librealsense（rs-enumerate-devices），出图得靠 SDK 或 ROS 包" ;;
        "") ;;
        *) ok "librealsense 已装"; dim "$RS" ;;
    esac
fi

# ─────────────────────── 3. 狗 <-> MID360 ───────────────────────
sec "3. 狗 ←→ MID360（以太网）"

LIDAR_IP=$(sed -n 's/.*"ip" *: *"\([0-9.]*\)".*/\1/p' \
           "${REPO_DIR}/src/livox_ros_driver2/config/MID360_config.json" 2>/dev/null | head -1)
LIDAR_IP="${LIDAR_IP:-unknown}"
ok "雷达地址 ${LIDAR_IP}（读自 MID360_config.json）"

REMOTE_MID360='
set -u
echo "IFACES|$(ip -br addr 2>/dev/null | grep -E "^eth|^en" | tr "\n" ";")"
echo "PING|$(ping -c 3 -W 1 '"$LIDAR_IP"' >/dev/null 2>&1 && echo OK || echo FAIL)"
echo "UDP|$(ss -lun 2>/dev/null | awk "/:56[1-5]0[0-9]/{print \$5}" | tr "\n" " ")"
echo "PROC|$(P="livox_ros_dri""ver2"; pgrep -af "$P" 2>/dev/null | grep -v "bash -c" | head -2 | tr "\n" ";")"
echo "LINK|$(for n in $(ls /sys/class/net | grep -E "^eth|^en"); do echo -n "$n:$(cat /sys/class/net/$n/carrier 2>/dev/null)@$(cat /sys/class/net/$n/speed 2>/dev/null)M "; done)"
echo "END"
'
M_OUT=$(DOG "$REMOTE_MID360")
if [ -z "$M_OUT" ]; then
    bad "远程命令无返回，跳过"
else
    echo "$M_OUT" | sed -n 's/^IFACES|//p' | tr ';' '\n' | while IFS= read -r l; do
        [ -n "$l" ] && dim "$l"
    done
    if echo "$M_OUT" | grep -q "^PING|OK"; then
        ok "狗能 ping 通雷达 ${LIDAR_IP}"
    else
        bad "狗 ping 不通雷达 ${LIDAR_IP}"
        dim "查：雷达上电了吗（转起来没）／网线插在狗的哪个口／两端是否同网段"
    fi
    LINKL=$(echo "$M_OUT" | sed -n 's/^LINK|//p')
    case "$LINKL" in
        *@1000M*) ok "网口千兆：${LINKL}" ;;
        *@100M*)  warn "网口只有百兆：${LINKL}（点云会丢包，检查网线是否 8 芯）" ;;
        *)        warn "网口链路：${LINKL:-读不到}" ;;
    esac
    U=$(echo "$M_OUT" | sed -n 's/^UDP|//p' | xargs 2>/dev/null)
    if [ -n "$U" ]; then ok "雷达端口在收：${U}"; else dim "56xxx 端口暂未监听（驱动没起时会这样，正常）"; fi
    P=$(echo "$M_OUT" | sed -n 's/^PROC|//p')
    [ -n "$P" ] && dim "驱动进程：${P}" || dim "livox 驱动未运行（只做链路检查时正常）"
fi

printf '\n\033[1m检查结束\033[0m\n'
