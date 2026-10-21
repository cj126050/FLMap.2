#!/bin/bash
# =============================================================
#  clock_sync.sh —— 有线模式下的时间基准工具（PC 侧入口）
#
#  为什么需要它
#  ------------
#  Orin Nano 载板没有 RTC 电池，断电后时钟回到镜像构建日。
#  而 FAST-LIO2 要把 10 Hz 点云和 200 Hz IMU 融合，两端只要差到几百毫秒，
#  PC 端 RViz 就会报 "Message Filter dropping message"，TF 全部过期。
#
#  有线让这件事变得便宜：RTT 只有 0.5 ms，一次 HTTP 采样就能校准到 1 ms 内。
#
#  用法
#  ----
#    ./scripts/clock_sync.sh start      # 在 PC 上起授时服务（后台常驻）
#    ./scripts/clock_sync.sh install    # 推到狗端安装 systemd 服务（需 sudo）
#    ./scripts/clock_sync.sh check      # 测当前偏差，只读
#    ./scripts/clock_sync.sh stop       # 停掉 PC 侧授时服务
#
#  环境变量:
#    EDGE_HOST  狗端 IP      默认 192.168.123.18
#    EDGE_USER  狗端用户名    默认 unitree
#    TIME_PORT  授时端口      默认 8000
# =============================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 目标地址由链路层决定（有线包不发散猜测），本脚本不写死网段。
# shellcheck source=lib_link.sh
source "$REPO_DIR/scripts/lib_link.sh"
EDGE_HOST="${EDGE_HOST:-$(link_resolve)}"
EDGE_USER="${EDGE_USER:-unitree}"
TIME_PORT="${TIME_PORT:-8000}"
LOG=/tmp/go2_timeserver.log
PIDF=/tmp/go2_timeserver.pid

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=15)
SSH="ssh ${SSH_OPTS[*]} ${EDGE_USER}@${EDGE_HOST}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; D='\033[2m'; N='\033[0m'
say() { echo -e "${C}[clock]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }
dim() { echo -e "${D}       $*${N}"; }

# 本机在 192.168.123.0/24 上的地址（授时服务要用它）
local_ip() {
    ip -4 -o addr show | awk '$4 ~ /^192\.168\.123\./ {sub(/\/.*/,"",$4); print $4; exit}'
}

# 判断 8000 上到底是不是"授时服务"，而不是只看端口有没有被占。
# 只看端口会误判：任何开发服务器占着 8000，脚本都会报 ok，然后狗端每 30 秒
# 拉回一段 HTML，解析失败、静默不校时 —— 这是最难查的一类故障。
probe_time_server() {
    local body=""
    if command -v curl >/dev/null 2>&1; then
        body=$(curl -fsS --noproxy '*' --max-time 2 \
               "http://127.0.0.1:${TIME_PORT}/time" 2>/dev/null)
    else
        body=$(python3 - "$TIME_PORT" <<'PY' 2>/dev/null
import sys, urllib.request
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
print(op.open("http://127.0.0.1:%s/time" % sys.argv[1], timeout=2).read().decode().strip())
PY
)
    fi
    # go2_timeserver 返回的是浮点 epoch，例如 1792387069.441716
    printf '%s' "$body" | grep -Eq '^[0-9]{9,}(\.[0-9]+)?$'
}

cmd_start() {
    local ip; ip=$(local_ip)
    [ -z "$ip" ] && die "PC 上没有 192.168.123.x 的地址 —— 先按 docs/02 §3 配有线口"
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ok "授时服务已在运行 (pid $(cat "$PIDF"))"; return 0
    fi
    if ss -ltn 2>/dev/null | grep -q ":${TIME_PORT} "; then
        if probe_time_server; then
            ok "端口 ${TIME_PORT} 上已有授时服务在响应 —— 直接复用"
            dim "不是本脚本这次拉起的（没有 pid 文件），但 /time 返回合法时间戳，可以用"
            return 0
        fi
        warn "端口 ${TIME_PORT} 被占用，但它不是授时服务："
        ss -ltnp 2>/dev/null | grep ":${TIME_PORT} " | sed 's/^/    /'
        dim "看不到 pid 就用: sudo lsof -i :${TIME_PORT}"
        echo
        warn "当前端口不可用，换一个："
        local alt=$((TIME_PORT + 1))
        dim "TIME_PORT=${alt} $0 start"
        warn "狗端也要跟着改（它默认连 192.168.123.10:8000）："
        dim "echo 'GO2_TIME_SERVER=${ip}:${alt}' | sudo tee /etc/default/go2-clock"
        dim "sudo systemctl restart go2-clock-pull.timer"
        die "端口 ${TIME_PORT} 不可用"
    fi
    nohup python3 "$REPO_DIR/tools/clock/go2_timeserver.py" --port "$TIME_PORT" --bind 0.0.0.0 \
        > "$LOG" 2>&1 &
    echo $! > "$PIDF"
    sleep 0.6
    if kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ok "授时服务已启动: http://${ip}:${TIME_PORT}/time"
        dim "日志 $LOG   pid $(cat "$PIDF")"
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            warn "ufw 已启用，狗可能连不上。放行：sudo ufw allow ${TIME_PORT}/tcp"
        fi
    else
        die "启动失败，看 $LOG"
    fi
}

cmd_stop() {
    local stopped=0
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        kill "$(cat "$PIDF")" 2>/dev/null && stopped=1
    fi
    # 字符类写法：避免 pkill 匹配到执行这条命令的 shell 自身
    pkill -f "go2_timeserver[.]py" 2>/dev/null && stopped=1
    rm -f "$PIDF"
    sleep 0.4

    if ss -ltn 2>/dev/null | grep -q ":${TIME_PORT} "; then
        if [ "$stopped" = "1" ]; then
            warn "已发出停止信号，但端口 ${TIME_PORT} 仍在监听"
        else
            warn "没有找到本脚本拉起的授时服务，但端口 ${TIME_PORT} 被占用"
        fi
        dim "查占用者: sudo lsof -i :${TIME_PORT}"
    elif [ "$stopped" = "1" ]; then
        ok "已停止"
    else
        warn "没有在跑的授时服务"
    fi
}

# 用与狗端相同的算法测偏差：3 次采样取最小 RTT，按单程补偿
cmd_check() {
    local ip; ip=$(local_ip)
    [ -z "$ip" ] && die "PC 上没有 192.168.123.x 的地址"
    python3 - "$EDGE_HOST" "${EDGE_USER}" "$TIME_PORT" "$ip" <<'PY'
import subprocess, sys, time, urllib.request

host, user, port, ip = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
url = "http://%s:%d/time" % (ip, port)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

try:
    with opener.open(url, timeout=2) as r:
        float(r.read().decode().strip())
except Exception as e:
    print("  \033[31m✗\033[0m PC 授时服务不可达 %s  (%s)" % (url, e))
    print("     先在 PC 上: ./scripts/clock_sync.sh start")
    sys.exit(1)

# 狗端用自己的 go2-clock status，走的是同一套采样逻辑
cmd = "command -v go2-clock >/dev/null && go2-clock status || echo 'NO_GO2_CLOCK'"
try:
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         "-o", "StrictHostKeyChecking=accept-new", "%s@%s" % (user, host), cmd],
        capture_output=True, text=True, timeout=25).stdout
except subprocess.TimeoutExpired:
    print("  \033[31m✗\033[0m ssh 超时")
    sys.exit(1)

print(out.rstrip() if out.strip() else "  （无输出）")
PY
}

cmd_install() {
    cmd_start
    say "推送到狗端…"
    $SSH 'mkdir -p ~/flmap3_clock' >/dev/null 2>&1 || die "ssh 不通"
    scp -q "${SSH_OPTS[@]}" "$REPO_DIR"/tools/clock/go2-clock \
        "$REPO_DIR"/tools/clock/install_go2_clock.sh \
        "${EDGE_USER}@${EDGE_HOST}:~/flmap3_clock/" || die "scp 失败"
    say "安装（需要狗端 sudo 密码）…"
    $SSH "cd ~/flmap3_clock && sudo bash install_go2_clock.sh" 2>&1 | sed 's/^/    /'
    echo
    cmd_check
}

case "${1:-check}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    check)   cmd_check ;;
    install) cmd_install ;;
    -h|--help) sed -n '2,25p' "$0" ;;
    *) echo "用法: $0 {start|install|check|stop}"; exit 1 ;;
esac
