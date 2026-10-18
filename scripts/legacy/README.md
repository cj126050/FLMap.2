# legacy/ —— 旧架构脚本（雷达直连 PC）

这两个脚本属于 FLMap.2 之前的架构：**Mid360 用网线直连 PC，建图和 RViz 都在 PC 上**。
在机器狗场景下这个架构不成立（雷达网口被狗占用了），所以移到此处留档：

| 脚本 | 用途 |
|---|---|
| `mid360_control.sh` | 单机版交互控制台（建图 + RViz + 录包） |
| `online_mapping.sh` | 单机版一键启动（驱动 + 建图 + 预览） |

它们依赖 `go2_fastlio` 包，仍然可用，但请勿与新架构混用 —— 两套流程会抢同一个
雷达 IP 和同一批话题。

新架构的入口是 `scripts/edge_control.sh`（狗端）+ `scripts/pc_view.sh`（PC 端）。
