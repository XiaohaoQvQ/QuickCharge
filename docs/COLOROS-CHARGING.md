# ColorOS 充电降流的真实链路

这份文档记录 3.2.1 重建壳温控制时依据的公开资料，以及代码里每条判断对应哪一条证据。
目的是让以后改这块的人不必重新考古，也避免再出现「凭电池温度推断降流原因」这种错判。

## 一句话

**ColorOS 的亮屏降流看的是壳温，不是电池温度。** 壳温到 36℃ 就进第 6 档，功率掉到
10W 量级。只压电池温度对它无效，所以「功率只有 5-10W」在只做电池伪装的模块上会稳定复现。

## 链路

```
shell_front / shell_frame / shell_back   (PMIC 热敏电阻，加权成 shell_temp)
        │  驱动 oplus,shell-temp
        ▼
com.oplus.thermalcontrol                 (用户态，约 3 秒轮询)
        │  按壳温查 /vendor/etc/charger_cool_down.conf 的 thresholds / levels
        ▼
charger HAL (ICharger)  applyLevel(n)
        ▼
/sys/class/oplus_chg/battery/cool_down   (0=不降流，非 0=降流档位)
        ▼
oplus_wired_current_set(cool_down_icl, cool_down)   (参与 ICL/FCC 计算)
```

灭屏与亮屏不是同一套：灭屏由内核按壳温自己限流，亮屏才交给 `com.oplus.thermalcontrol`。
这解释了一个老现象——同一个 `cool_down` 值，灭屏时功率正常、亮屏时掉到 10W。

## 证据

| 结论 | 来源 |
|---|---|
| 亮屏降流由 `com.oplus.thermalcontrol` 应用 `charger_cool_down.conf` 的档位 | LineageOS `android_hardware_oplus` change 512011 commit message |
| 配置格式为 `sensors` / `thresholds` / `thresholds_clr` / `levels`，轮询 3 秒，通过 charger HAL `applyLevel` 下发 | 同上，`power/charger-cool-down.cpp` |
| 档位来自 `sys_thermal_control_config.xml` 的 charge action | LineageOS change 512010 |
| 36℃ 进第 6 档（`cool_down=6`），37℃ 为 2 档，30℃ 以下解除 | OPLUS 温控配置解析（CSDN 文库） |
| 写 `1` 到 `cool_down` = 只允许约 10W 充电 | XDA 一加 12R 讨论帖（`echo 1 > .../battery/cool_down`） |
| 壳温是 `shell_front` / `shell_frame` / `shell_back` 三路拟合，不是电池温度 | 酷安 dtbo 去温控教程；DeepWiki OPPO 内核文档（`oplus,shell-temp`） |
| `cool_down` / `cool_down_icl` 参与 `oplus_wired_current_set` | OPLUS_CHG 内核日志字段 |
| 壳温覆盖需要 `emul_temp` 与 `/proc/shell-temp` 双路径，并压制 Horae/thermal-HAL | Vehemence 模块说明（同类实现的公开描述） |

## 我们的实现

`lib/plat/shell.sh` 做了三件事：

1. **压壳温**。优先写 `thermal_zone/N/emul_temp`（内核级，HAL 也读这个值），
   其次写 `/proc/shell-temp`（oplus 私有 proc）。`/proc/shell-temp` 的格式因机型而异，
   所以第一次从文件原文反推（`idx` / `name` / `plain`），结果缓存到 `run/shell.fmt`，
   不硬编码。
2. **回读确认**。写完读三路 `temp`，最高值与目标差 ≤2℃ 才算压住。以前的实现写完就
   当生效，服务把它清掉了也发现不了——这是「明明设了 30℃ 却照样降流」的直接原因。
3. **归因**。`sd_pwr_cause` 把 `cool_down` 与壳温状态交叉，输出五种之一：

| 归因 | 含义 | 处置 |
|---|---|---|
| `spoof_off` | 温度伪装没开 | 不干预，正常 |
| `ok` | `cool_down=0` | 没被降流 |
| `low_power` | `cool_down=1` | ColorOS 的「仅 10W」开关被打开了，与温度无关 |
| `spoof_failed` | 壳温没压住且正在降流 | 伪装失效，查 `why=`（`no_node`/`write_fail`/`no_effect`） |
| `thermal` | 壳温压住了仍降流 | 来源不是壳温：电池温度、HAL 或手动档位 |

日志里长这样：

```
I [env] cool_down=6（/sys/class/oplus_chg/battery/cool_down） cause=spoof_failed shell=30/38 why=no_effect
I [chg] cool=6 cause=spoof_failed shell=30/38（亮屏降流档位，只记录不写入）
W [chg] 壳温没压住，降流是它触发的：target=30℃ 实测=38℃ reason=no_effect
```

## 为什么不直接写 cool_down=0

三个机型实测过，写它会让驱动重选档、重走协议协商：

| 机型 | 动作 | 结果 |
|---|---|---|
| PKB110 | 2→0 | 18W → 9.7W，抖到 6W |
| PKX110 | 0→1 | 32W → 9W，tech 7→14 |
| PJD110 | 3→0 | 33.6W → 2.2W，45 分钟没回到 10W 以上（vusb 8V→5.15V、imax 2A→0.5A、vooc 1→0） |

对照组：同一分钟驱动自己把 `cool_down` 清到 0，功率 31.5W 正常。**同一个值，差别只在
谁写的。** 所以正确做法是让壳温低到系统自己解除档位，而不是替它写结果。

## 接到 5-10W 反馈时怎么用

按顺序看三行：

1. `[env] shell-zone=N` —— 0 表示这台机器没有壳温节点，压不了壳温，只能靠电池路径。
2. `[env] cause=` —— `spoof_failed` 是本模块的责任，`thermal` 是别的来源，
   `low_power` 是开关。
3. `[chg] 壳温没压住` —— 带 `why=`，直接指向是节点缺失、写不进、还是写了没反应。

`why=no_effect` 且 `emul=0` = 内核没开 `CONFIG_THERMAL_EMULATION`，只能靠
`/proc/shell-temp`；两者都没有时，除了解锁温控（改 dtbo / 换内核）没有软件办法。
