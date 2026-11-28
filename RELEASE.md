# Quick Charge v3.1.16

这一版把「模块不生效」这一类问题，从**只能猜**变成**日志里直接看得到**。

3.1.15 之后一加 15 的现场日志显示：装的是 3.1.15-c、跑的也是 3.1.15-c，指纹对得上，
用户却仍然「完全不生效」。原因不在版本——那次开机 `post-fs-data` 根本没执行，而模块
没有留下任何能证明这一点的痕迹；同时挂载存活检查把「覆盖层和系统文件内容相同」当成
「还挂着」，于是「改写没产生效果」被伪装成了「一切正常」。

## post-fs-data 失败可观测

- 新增 `$SD_DATA/phase.pfs`：`post-fs-data.sh` 在**加载 lib 之前**就用纯 sh 逐阶段写
  `step=`（`boot` / `zones` / `build` / `mount` / `done`），任何 `exit` 之前都落一笔；
- `service.sh` 读它：文件缺失或早于本次开机 = 没执行；停在非 `done` = 中途失败或被杀。
  两种情况都打一条 `W [boot]`，并写明停在哪一步、`argv0`/`cwd` 是什么；
- `MODDIR` 推导改成多路径探测：`SD_MODDIR` → `/data/adb/modules/quickcharge` →
  `/data/adb/modules_update/quickcharge` → `$0` 所在目录 → `pwd`，命中 `lib/qc.sh` 即用。
  管理器用相对路径执行时不再直接 `exit 1` 且无声无息。

## 覆盖层不再「假装还挂着」

- 删掉 `sd_mounts_content_ok` 的「内容相同 = 挂载还在」判定，改为按
  `/proc/self/mountinfo` 的 root 字段是否落在覆盖层目录下判断；
- `sd_transform` 改写后与原文件逐字节比对：相同就**不写入覆盖层**，并打
  `W [override] 改写无差异: <路径>`，汇总行变成「改写 N · 无差异 M · 跳过 K · 失败 J」；
- `service.sh` 发现 `post-fs-data` 没跑完时，**无条件重建覆盖层再挂**，不再只信存活检查。

## 平台判定：shell 与 C 对齐

- shell 的 `_sd_curr_prepare` 原来在 `sd_plat_resolve` **之前**就早退，导致「表建好之后
  平台才认对」的情况永远补不上 MTK 那 5 个候选节点。现在每次进来都先探一次；
- 探测预算从「8 次调用」改成「300 秒时间窗」：`_sd_curr_prepare` 一轮可能被调用多次
  （`sd_scr_fcc_node` 每轮都调），按次数算的话 8 次在一个 tick 内就烧完，等于没给启动
  早期留窗口；
- 重建成功时打一条 `I [charge] 平台已认对（mtk），候选表按新平台重算`，现场能确认它跑了。

## 其它

- C 侧 qcom 关键字补齐 `canoe` / `kalama` / `crow` / `alor`（一加 15 的 SM8850 平台名是
  `canoe`，之前被认成 `other`，面板显示「其他」）；
- C 侧 fb 路径改为 `/sys/class/graphics/fb0/blank` 优先，日志不再打印一个不存在的路径；
- `[env]` 新增 `overrides=N mounts=N nm=bind|nomount alive=yes|no`，覆盖层状态一眼可读；
- `RELEASE.md` 里「`action.sh` 的 start/restart」改为「`restart`」——没有 `start` 子命令。

升级后如果日志首行仍是「清理上一轮日志（post-fs-data 未执行）」，请把
`su -c 'sh /data/adb/modules/quickcharge/post-fs-data.sh; echo rc=$?'` 的 stderr 发回来，
现在它会明确告诉你停在哪一步。
