# Quick Charge v3.2.1

按 ColorOS 真实链路重建壳温控制。这一版不再猜「功率为什么上不去」，而是把
ColorOS 的降流链路整条接过来，并且每一步都回读确认。

## 5-10W 的根因

ColorOS 的亮屏降流**不看电池温度，看壳温**：内核 `oplus,shell-temp` 把
`shell_front` / `shell_frame` / `shell_back` 三路 PMIC 热敏电阻加权成 `shell_temp`，
`com.oplus.thermalcontrol` 每 3 秒按壳温查 `/vendor/etc/charger_cool_down.conf`，
经 charger HAL 下发档位，最后落到 `/sys/class/oplus_chg/battery/cool_down`。
**壳温到 36℃ 就进第 6 档，功率掉到 10W 量级。**

之前的实现只伪装电池温度（`batt`）和核心温度（`core`），壳温一路没碰。所以
「电池 33℃、壳温 40℃」的机器照样降流，而日志里只留下一句
`cool_down=6（亮屏降流标记，只记录不写入）`——把根因判成了无关变量。

## 改了什么

**1. 新增 `lib/plat/shell.sh`（328 行）**

- 壳温三件套识别：`shell_front` / `shell_frame` / `shell_back`，同时兼容
  `shell-back` 这类连字符命名。
- 两条主写入路径：`thermal_zone/N/emul_temp`（内核级，HAL 读的也是它）→
  `/proc/shell-temp`（oplus 私有 proc）。第三路径 bind mount 只遮用户态路径，
  对 HAL 无效，默认关闭（`SD_SHELL_BIND=1` 才启用），不再拿它冒充生效。
- `/proc/shell-temp` 的格式不硬编码：第一次从文件原文反推 `idx` / `name` / `plain`，
  缓存到 `run/shell.fmt`。
- **每次写完回读三路 `temp`**，最高值与目标差 ≤2℃ 才算压住。

**2. `cool_down` 从「只读标记」改为归因**

| cause | 含义 |
|---|---|
| `spoof_off` | 温度伪装没开，本来就不干预 |
| `ok` | `cool_down=0`，没被降流 |
| `low_power` | `cool_down=1`，ColorOS 的「仅 10W 充电」开关被打开了 |
| `spoof_failed` | 壳温没压住且正在降流——这是模块的责任 |
| `thermal` | 壳温压住了仍降流，来源不是壳温 |

仍然**不写** `cool_down`：三台机器实测写它会让驱动重选档、重走协议协商
（PJD110 写 3→0 后 33.6W 掉到 2.2W，45 分钟没回来）。正确做法是让壳温低到
系统自己解除档位。

**3. 日志直接回答「为什么」**

```
I [env] shell-zone=3 ... cool_down=6（...） cause=spoof_failed shell=30/38 why=no_effect
W [chg] 壳温没压住，降流是它触发的：target=30℃ 实测=38℃ reason=no_effect
```

## 前提与限制

- 需要内核开了 `CONFIG_THERMAL_EMULATION`（有 `emul_temp`），或 `/proc/shell-temp`
  可写。两者都没有时软件无法压壳温，日志会报 `why=no_node` / `why=write_fail`。
- 壳温压低只影响按壳温的降流策略；电池温度过高时驱动仍会自己限流，这属于正常保护。
- **C 通道（QuickCharge-C）这版没跟进**，仍是 3.1.18-c。C 版的控制在 `bin/qcmon`
  里，壳温链路要单独移植，装 C 版仍可能出现 5-10W。

## 验证

- 仿真 `tests/sim/run.sh`：661 → **671**，新增 T60 十条（格式自适应、回读不符报
  `no_effect`、回读一致报生效、归因五态、连字符命名）。
- `tests/preflight.sh --self`：全绿，新增 6 条守卫（回读校验、`no_effect`、归因、
  格式探测，以及「旧文案/硬编码通道循环不得回退」）。
- 单元测试五项合计 89 项、C 冒烟 105 项，均未受影响。

## 升级说明

配置不迁移（沿用 3.2.0 的选择）。升级后温度校准、曲线偏移、模式选择回默认。
