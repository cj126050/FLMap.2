#!/usr/bin/env bash
# L0 一键回归：合成数据 -> 关键帧 -> nerfstudio 数据集 -> 投影自检
#
# 目的：在没有相机、没有狗的情况下，验证方案 B（半边缘）里除了"训练"以外的
# 每一个环节。跑通不代表现场一定行，但跑不通就肯定不行。
#
# 用法：
#   ./tools/sim/run_sim.sh                     # 默认 120 帧，输出到 data/sim
#   ./tools/sim/run_sim.sh /tmp/sim 60         # 指定目录与帧数
#
# 注意：/tmp 在很多机器上是 10 MB 的 tmpfs（本机就是），120 帧约 13 MB 会写爆。
# 默认落在仓库外的 data/ 下，别用 /tmp。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$REPO/data/sim}"
FRAMES="${2:-120}"
PY="${PY:-/usr/bin/python3}"

echo "== L0 合成数据回归 =="
echo "   输出: $OUT"
echo "   帧数: $FRAMES"
echo

"$PY" "$HERE/make_synthetic.py" --out "$OUT" --frames "$FRAMES"

echo
"$PY" "$HERE/sim_edge_loop.py" \
    --scene "$OUT/room0" \
    --out "$OUT/kf"

echo
"$PY" "$HERE/build_dataset.py" \
    --kf "$OUT/kf" \
    --out "$OUT/ds" \
    --points 200000

echo
"$PY" "$HERE/check_projection.py" \
    --dataset "$OUT/ds" \
    --kf "$OUT/kf" \
    --scene "$OUT/room0" \
    --frames 3 \
    --out "$OUT/proj_check.png"

echo
echo "== 单元测试 =="
"$PY" "$HERE/test_kf_core.py"

echo
echo "下一步（需要 GPU，在你自己终端里跑）："
echo "  ns-train splatfacto --data $OUT/ds --pipeline.model.random-init False \\"
echo "      --max-num-iterations 30000"
echo
echo "产物："
echo "  $OUT/room0       合成场景（rgb + depth + traj）"
echo "  $OUT/kf          关键帧（image.jpg + pose.txt + cloud.pcd）"
echo "  $OUT/ds          transforms.json + init.ply + images/"
echo "  $OUT/proj_check.png  投影叠图"
