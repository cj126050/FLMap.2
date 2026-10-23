#!/usr/bin/env bash
# 狗端相机可用性诊断：Type-C / USB / MIPI-CSI 三条路一次问到底。
#
# 用法（在 PC 上跑）：
#   ./scripts/dog_camera_check.sh                 # 静态体检 + 给结论
#   ./scripts/dog_camera_check.sh --watch=25      # 体检后盯 25 秒热插拔（期间请拔下再插上相机）
#   ./scripts/dog_camera_check.sh --host=10.42.0.18
#
# 判定链：视频节点 → USB 枚举 → CSI sensor(i2c) → ISP/Argus → USB 口角色。
# 全程只读，不改任何配置、不装包。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib_link.sh
. "$HERE/lib_link.sh" 2>/dev/null || true

WATCH=0
EDGE_HOST="${EDGE_HOST:-}"
for a in "$@"; do
    case "$a" in
        --watch=*) WATCH="${a#*=}" ;;
        --host=*)  EDGE_HOST="${a#*=}" ;;
        --help|-h) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$a"; exit 2 ;;
    esac
done

HOST=$(link_resolve 3 2>/dev/null)
[ -n "$HOST" ] || HOST="${LINK_DEFAULT_HOST:-10.42.0.18}"

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
sec() { printf '\n%s── %s%s\n' "$B" "$1" "$N"; }
ok()  { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
bad() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
dim() { printf '     %s%s%s\n' "$D" "$1" "$N"; }

if ! ping -c1 -W2 "$HOST" >/dev/null 2>&1; then
    bad "狗端 $HOST 不通，先解决链路"
    dim "无线： sudo ./scripts/pc_hotspot.sh --chan=44  然后 ./scripts/postboot_check.sh"
    exit 20
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "unitree@$HOST")
printf '%s\n' "============================================================"
printf ' 狗端相机诊断   %s   host=%s\n' "$(date '+%F %T')" "$HOST"
printf '%s\n' "============================================================"

# ------------------------------------------------------------ 远程采集
OUT=$(timeout 60 "${SSH[@]}" 'bash -s' <<'EOS' 2>&1
echo "@@VIDEO_N=$(ls /dev/video* 2>/dev/null | wc -l)"
echo "@@VIDEO_LIST=$(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
echo "@@MEDIA_N=$(ls /dev/media* 2>/dev/null | wc -l)"
echo "@@UVC_N=$(lsusb 2>/dev/null | grep -ciE 'camera|webcam|uvc|imaging|video')"
echo "@@USBDEV=$(lsusb 2>/dev/null | grep -v 'root hub' | sed 's/^.*ID /   /' | tr '\n' '|')"
echo "@@USB_PORTS=$(ls /sys/bus/usb/devices/ 2>/dev/null | grep -cE '^[0-9]+-[0-9]+$')"
echo "@@IMX_FAIL=$(sudo -n dmesg 2>/dev/null | grep -c 'imx219.*failed')"
echo "@@IMX_ERR=$(sudo -n dmesg 2>/dev/null | grep -m1 'imx219.*error' | sed 's/^\[[^]]*\] //')"
echo "@@ARGUS=$(systemctl is-active nvargus-daemon 2>/dev/null)"
echo "@@CAMCHAR=$(ls /dev/camchar-* 2>/dev/null | wc -l)"
if [ -e /sys/devices/platform/3550000.xudc/driver ]; then echo "@@XUDC=bound"; else echo "@@XUDC=unbound"; fi
echo "@@XUDC_ERR=$(sudo -n dmesg 2>/dev/null | grep -c 'xudc.*failed')"
echo "@@I2C9=$(sudo -n i2cdetect -y -r 9 2>/dev/null | grep -c '^10:.*10')"
echo "@@I2C10=$(sudo -n i2cdetect -y -r 10 2>/dev/null | grep -c '^10:.*10')"
echo "@@V4L2=$(command -v v4l2-ctl >/dev/null 2>&1 && echo yes || echo no)"
echo "@@KERN=$(uname -r)"
EOS
)

getv() { printf '%s\n' "$OUT" | grep -m1 "^@@$1=" | cut -d= -f2-; }

VIDEO_N=$(getv VIDEO_N); VIDEO_LIST=$(getv VIDEO_LIST)
MEDIA_N=$(getv MEDIA_N); UVC_N=$(getv UVC_N)
USBDEV=$(getv USBDEV); USB_PORTS=$(getv USB_PORTS)
IMX_FAIL=$(getv IMX_FAIL); IMX_ERR=$(getv IMX_ERR)
ARGUS=$(getv ARGUS); CAMCHAR=$(getv CAMCHAR)
XUDC=$(getv XUDC); XUDC_ERR=$(getv XUDC_ERR)
I2C9=$(getv I2C9); I2C10=$(getv I2C10)
V4L2=$(getv V4L2)

# ------------------------------------------------------------ 1. 视频节点
sec "1. 视频节点（最硬的证据）"
if [ "${VIDEO_N:-0}" -gt 0 ]; then
    ok "找到 $VIDEO_N 个 /dev/video*：$VIDEO_LIST"
    dim "能出节点就说明有驱动认领了摄像头，可以直接抓流"
else
    bad "没有任何 /dev/video* —— 内核层没有可用的摄像头设备"
    [ "${MEDIA_N:-0}" -gt 0 ] && dim "/dev/media* 有 $MEDIA_N 个：这是 CSI/ISP 的拓扑节点，只表示链路注册了，不代表有 sensor"
fi

# ------------------------------------------------------------ 2. USB 枚举
sec "2. USB 枚举（Type-C 口有没有认到设备）"
dim "USB 端口占用 ${USB_PORTS:-?} 个；设备清单："
printf '%s\n' "${USBDEV:-}" | tr '|' '\n' | sed '/^$/d' | sed 's/^/     /'
if [ "${UVC_N:-0}" -gt 0 ]; then
    ok "列举到疑似摄像头类 USB 设备"
else
    bad "lsusb 里没有任何摄像头类设备（只剩无线网卡/根 hub）"
    dim "插上相机后如果这里没有新增一行，说明这个口根本没把它当从设备枚举"
fi

# ------------------------------------------------------------ 3. CSI sensor
sec "3. MIPI-CSI 传感器（Go2 原厂相机走这条）"
I2C_HIT=$(( ${I2C9:-0} + ${I2C10:-0} ))
if [ "${IMX_FAIL:-0}" -gt 0 ]; then
    bad "IMX219 探测失败 ${IMX_FAIL} 次 —— 驱动在板，但 sensor 不应答"
    [ -n "${IMX_ERR:-}" ] && dim "内核原话：$IMX_ERR"
    if [ "$I2C_HIT" -gt 0 ]; then
        dim "i2c-9/i2c-10 的 0x10 有应答，但寄存器读不进去 —— 供电或时钟没起来"
    else
        dim "i2c-9/i2c-10 的 0x10 全空 —— sensor 根本不在总线上（没接/没供电）"
    fi
    dim "→ 排线没插好 / 模组没供电 / 相机压根不在这块板上"
else
    warn "没有 IMX219 探测记录（可能驱动没加载，或这版设备树没启用 CSI）"
fi

# ------------------------------------------------------------ 4. 取流服务
sec "4. 取流链路（ISP / Argus）"
[ "$ARGUS" = "active" ] && ok "nvargus-daemon 在跑（硬件链路已就绪，缺的是 sensor）" \
                        || warn "nvargus-daemon 未运行：$ARGUS"
[ "${CAMCHAR:-0}" -gt 0 ] && dim "camchar 设备 ${CAMCHAR} 个（ISP 字符设备已注册）"
dim "Go2 原厂前置相机对外不是 V4L2，而是 DDS 上的 Go2FrontVideoData（/frontvideostream）"
dim "当前无任何视频服务进程在发布这条流"

# ------------------------------------------------------------ 5. USB 角色
sec "5. Type-C 口角色"
if [ "$XUDC" = "unbound" ]; then
    warn "3550000.xudc（USB device 控制器）没有绑定驱动，启动期报错 ${XUDC_ERR:-?} 次"
    dim "这个口的默认角色是「从设备」（把狗当 U 盘/网卡接到 PC），不是 host"
    dim "host 控制器 3610000.xhci 上只挂了无线网卡 1-2，Type-C 插相机不会出现在那里"
else
    ok "xudc 已绑定（该口可作为从设备被 PC 识别）"
fi

# ------------------------------------------------------------ 结论
sec "结论"
if [ "${VIDEO_N:-0}" -gt 0 ]; then
    ok "相机可用"
    [ "$V4L2" = "yes" ] && dim "取流： v4l2-ctl --device=/dev/video0 --stream-mmap --stream-count=30" \
                        || dim "缺 v4l2-utils： sudo apt install -y v4l-utils（狗要能上网）"
elif [ "${UVC_N:-0}" -gt 0 ]; then
    warn "USB 相机被认到了，但没出 /dev/video* —— 多半是 uvcvideo 没加载"
    dim "在狗端： sudo modprobe uvcvideo && ls /dev/video*"
elif [ "${IMX_FAIL:-0}" -gt 0 ]; then
    bad "两条路都不通：Type-C 上没有相机枚举，CSI 侧 sensor 也不应答"
    dim "Type-C：接的是相机没用 —— 这个口在狗上是 device 角色，只能被 PC 认成设备"
    dim "CSI：查排线两端（模组侧 + 主板 CSI 座），插到底、卡扣压紧，再冷启动一次"
else
    bad "用不了：这个口上没有任何相机设备"
    dim "Type-C 大概率是 device 口（给 PC 认狗用的），接 UVC 相机天然不通"
    dim "要么改用 Go2 原厂 CSI 模组接主板 CSI 座，要么换到真正的 USB-A host 口"
fi

# ------------------------------------------------------------ 热插拔监听
if [ "${WATCH:-0}" -gt 0 ]; then
    sec "热插拔监听 ${WATCH}s"
    warn "现在开始计时 —— 请把相机拔下，停 3 秒，再插回去"
    echo
    timeout "$WATCH" "${SSH[@]}" "sudo -n dmesg -w 2>/dev/null | grep -m20 -Ei 'usb|imx219|video|uvc'" 2>&1 | sed 's/^/     /'
    echo
    dim "上面若 20 行内没有新事件，就是这个口物理上不通（不是驱动问题）"
fi
