#!/bin/bash
# 明天回来接着干：一键恢复相机推流
#   跑法：ssh unitree@192.168.123.18 'bash ~/cam_resume.sh'
#   或者上狗直接：bash ~/cam_resume.sh
set -u
export MVCAM_COMMON_RUNENV=/opt/MVS/lib
export LD_LIBRARY_PATH=/opt/MVS/lib/aarch64:${LD_LIBRARY_PATH:-}

echo "=== 1. 相机在不在 ==="
if ! lsusb | grep -q "2bdf:0001"; then
    echo "✗ 没找到海康相机（2bdf:0001）"
    echo "  检查：相机是否插在能通的 USB3 口（lsusb -t 里应有 5000M）"
    exit 1
fi
lsusb -t 2>/dev/null | grep -A0 "5000M" | head -2

echo "=== 2. 时钟（狗无 RTC 电池，断电必回退）==="
date
if command -v go2-clock >/dev/null 2>&1; then
    # 状态文件在 /var/lib/go2-clock（root 所有），手工跑要用 sudo，
    # 否则只会打一行 "Permission denied"，时间其实没校准。
    if sudo -n true 2>/dev/null; then
        sudo -n go2-clock pull 2>&1 | tail -2
    else
        go2-clock pull 2>&1 | tail -2
    fi
    echo "  注：go2-clock-pull.timer 每 30s 自动跑（以 root），一般无需手工干预"
else
    echo "  （没装 go2-clock，跳过）"
fi

echo "=== 3. 起推流 ==="
if ss -ltn 2>/dev/null | grep -q ":8080"; then
    echo "  8080 已在监听，先停旧的"
    for p in $(pgrep -x python3); do
        tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -q "mvs_stre""am.py" && kill -9 "$p"
    done
    sleep 2
fi

WS="${EDGE_WS:-$HOME/flmap3_ws}"
SCRIPT="$WS/tools/mvs_stream.py"
[ -f "$SCRIPT" ] || SCRIPT="$HOME/FLMap.3/tools/mvs_stream.py"
if [ ! -f "$SCRIPT" ]; then
    echo "✗ 找不到 mvs_stream.py"
    echo "  从主机推一份：scp ~/FLMap.3/tools/mvs_stream.py unitree@192.168.123.18:~/flmap3_ws/tools/"
    exit 2
fi

setsid /usr/bin/python3 -u "$SCRIPT" \
    --expo 30000 --gain 10 --scale 4 --quality 75 --port 8080 \
    </dev/null >/tmp/cam.log 2>&1 &

sleep 8
echo "--- 日志 ---"
tail -6 /tmp/cam.log
echo "--- 统计 ---"
curl -s -m 5 http://127.0.0.1:8080/stats; echo
echo
echo "主机上看： http://192.168.123.18:8080/"
echo "主机命令： cd ~/FLMap.3 && ./scripts/cam_view.sh --open"
