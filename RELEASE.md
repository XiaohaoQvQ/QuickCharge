# Quick Charge v2.9.72（shell 版）

> 对应包：`QuickCharge-v2.9.72.zip` · `versioncode 29625`

日志三处修整：不再记录已取消的协议结论、C 守护时间戳回到本地时区、充电现场行不再被采样噪声刷屏。

## 一、协议判定退出日志

面板在 2.9.67 就不显示协议了，日志里却还在刷 `[proto] → vooc（tech=13）`，每行充电现场也挂着 `proto=vooc`——用户看到的是「界面没有，日志还在记」。

现在两侧都删掉：

- C 守护：删除 `chg_proto()` 整函数、`g_proto_last` 缓存、`[proto]` 事件行，充电行与启动 env 行去掉 `proto=` 字段。
- shell：`sd_chg_line_fill` 不再调用 `sd_proto_resolve`，判重签名与日志行同步去掉 `proto=`；`sd_chg_snapshot` 的协议切换事件删除。

保留的是**现场节点**，不是结论：`type=` / `rtype=` / `vooc=` / `tech=` 仍照抄，排查「为什么只有 9V/2A」时这几项是唯一直接证据。`sd_proto_resolve` 只服务 `action.sh check`，不再进日志。

`action.sh power` 的 JSON 也去掉了 `proto` 字段，功耗卡标题的「未接充电器」改由 `status` 判断（非 `Charging` / `Full` 即未接），少读一组节点。

## 二、C 守护时间戳回到本地

日志里 `[chg]` 是 `14:27`、`[env]` 是 `22:27`，差 8 小时——脚本写本地时间，静态编译的 qcmon 落 UTC。

原因：qcmon 是静态二进制，没有 tzdata，`localtime_r` 依赖 `TZ`；原来靠 `popen("date +%z")` 取偏移，在这台机器上没成功，整份日志退回 UTC。

修法两层：

1. `service.sh` 在 `exec qcmon` 前 `export SD_TZ=$(date +%z)`，守护直接解析这串 `+0800`，不依赖 popen。
2. 没有 `SD_TZ` 时回退到 `popen("/system/bin/date +%z")`，再退到 `date +%z`，两条都失败才放弃。

## 三、日志减噪

| 原来 | 现在 |
|---|---|
| `zones=80 emul=[thermal_zone0 thermal_zone1 … 80 个名字]` | `emul=80（thermal_zone0 thermal_zone1 thermal_zone2 …）` |
| 每次读充电现场都因 9.0V↔9.2V 抖一条「变化」 | `usb` 按整伏四舍五入分档，9.0-9.4 同档；9V→5V 掉档仍立刻记 |
| 开日志时 shell 与 C 各打一条「首帧」 | 有 C 守护时 shell 不再打，交给守护下一拍 |

## 验证

| 套件 | 结果 |
|---|---|
| `c-test` | 78（协议用例改为「行里不再带 proto」）|
| `chg-unit` | 44（同上）|
| `cool-unit` | 20 |
| `mount` / `zone` | 4 / 6 |
| `state-unit` | 12 |
| `sim` | 643（+4：两侧不再输出 `proto`、C 不写 `[proto]` 事件、充电行无 `proto`）|

时间戳用 `SD_TZ=+0800` 与不设 `SD_TZ` 两条路径各跑一次守护，日志首行都与 `date` 一致；`grep -c proto` 为 0。
