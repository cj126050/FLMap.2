#!/bin/bash
# =============================================================
#  cam_view.sh —— 主机端：看狗上那台海康 MV-CS060 的实时画面
#
#  干嘛的
#  ------
#  相机挂在狗（Go2）的 USB3 口上，狗端跑 tools/mvs_stream.py 把 JPEG 帧
#  用 MJPEG over HTTP 推出来，这里只是把地址找出来、探一下活、再开浏览器。
#
#  用法
#  ----
#    ./scripts/cam_view.sh              # 探活 + 打印地址
#    ./scripts/cam_view.sh --open       # 顺带用默认浏览器打开
#    ./scripts/cam_view.sh --snap out.jpg   # 存一张当前画面
#    ./scripts/cam_view.sh --fast       # 狗端没起时，给一键起服务的命令
#
#  端点（由 tools/mvs_stream.py 提供）
#  -----------------------------------
#    /              网页，带帧率显示
#    /stream        MJPEG 流（multipart/x-mixed-replace）
#    /snapshot      单张 JPEG
#    /stats         JSON：fps / efps / w / h / expo / gain / frames
#    /expo=30000    改曝光（微秒）
#    /gain=12       改增益（dB）
# =============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib_link.sh"

PORT="${CAM_PORT:-8080}"
OPEN=0
SNAP=""
FAST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --open) OPEN=1 ;;
        --snap) SNAP="${2:-cam_snapshot.jpg}"; shift ;;
        --fast) FAST=1 ;;
        --port) PORT="${2:-8080}"; shift ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^#//;s/^ //'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

EDGE_HOST="${EDGE_HOST:-$(link_resolve 8)}"
if [ -z "$EDGE_HOST" ]; then
    echo "✗ 找不到狗端地址（$LINK_DESC）" >&2
    link_check_hints 2>/dev/null
    exit 1
fi
BASE="http://${EDGE_HOST}:${PORT}"

echo "狗端 $EDGE_HOST  端口 $PORT"

# ── 探活：先看端口通不通，再看有没有在出帧
if ! timeout 3 bash -c "</dev/tcp/$EDGE_HOST/$PORT" 2>/dev/null; then
    echo "✗ 端口 $PORT 不通 —— 狗端推流服务没起来"
    if [ "$FAST" = "1" ]; then
        cat <<EOF

在狗上执行（相机必须插在 USB3 口，且没被别的进程占用）：

  export MVCAM_COMMON_RUNENV=/opt/MVS/lib
  export LD_LIBRARY_PATH=/opt/MVS/lib/aarch64:\$LD_LIBRARY_PATH
  cd ~/flmap3_ws 2>/dev/null || cd ~
  setsid python3 $REPO_DIR/tools/mvs_stream.py \\
      --scale 4 --quality 75 --port $PORT \\
      </dev/null >/tmp/cam.log 2>&1 &

注意：
  · 一定要 setsid 或 systemd-run，普通 nohup 会随 ssh 会话一起被干掉
  · 常驻别用 SSH 前台跑，退出就断流
  · 相机是 USB3 Vision，不产生 /dev/video*，OpenCV/arv-viewer 都打不开它
EOF
    else
        echo "  加 --fast 看狗端启动命令"
    fi
    exit 2
fi

# ── 读统计
STATS=$(curl -s -m 4 "$BASE/stats" 2>/dev/null)
if [ -z "$STATS" ]; then
    echo "✗ 端口通但 /stats 没响应 —— 服务可能在启动中，或有别的程序占着 $PORT"
    exit 3
fi

FPS=$(echo "$STATS" | sed -n 's/.*"fps":\([0-9.]*\).*/\1/p')
EFPS=$(echo "$STATS" | sed -n 's/.*"efps":\([0-9.]*\).*/\1/p')
W=$(echo "$STATS" | sed -n 's/.*"w":\([0-9]*\).*/\1/p')
H=$(echo "$STATS" | sed -n 's/.*"h":\([0-9]*\).*/\1/p')
EXPO=$(echo "$STATS" | sed -n 's/.*"expo":\([0-9]*\).*/\1/p')
GAIN=$(echo "$STATS" | sed -n 's/.*"gain":\([0-9.]*\).*/\1/p')
FRAMES=$(echo "$STATS" | sed -n 's/.*"frames":\([0-9]*\).*/\1/p')

echo "✓ 在出图  ${W}x${H}  采集 ${FPS}fps  编码 ${EFPS}fps  已 ${FRAMES} 帧"
echo "  曝光 ${EXPO}us   增益 ${GAIN}dB"

# 帧率为 0 的常见原因，直接提示，省得来回问
if [ "${EFPS:-0}" = "0" ] || [ "${EFPS:-0}" = "0.00" ]; then
    echo "⚠ 编码帧率是 0 —— 看 /tmp/cam.log。通常是没装 PIL 或 numpy，"
    echo "  或者还在编第一帧（Jetson 上首帧要几秒）"
fi

echo
echo "  网页    $BASE/"
echo "  截图    $BASE/snapshot"
echo "  调曝光  ${BASE}/expo=60000   （暗就加大，过曝就减小）"
echo "  调增益  ${BASE}/gain=12      （dB）"

if [ -n "$SNAP" ]; then
    if curl -s -m 10 -o "$SNAP" "$BASE/snapshot"; then
        SZ=$(stat -c%s "$SNAP" 2>/dev/null || echo 0)
        echo
        echo "✓ 已存 $SNAP（${SZ} 字节）"
    else
        echo "✗ 截图失败" >&2
        exit 4
    fi
fi

if [ "$OPEN" = "1" ]; then
    URL="$BASE/"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL" >/dev/null 2>&1 &
    elif command -v sensible-browser >/dev/null 2>&1; then
        sensible-browser "$URL" >/dev/null 2>&1 &
    else
        echo "（没找到 xdg-open，请手动打开 $URL）"
    fi
fi

exit 0
