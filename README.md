# Quick Charge (QC)

ColorOS / RealmeUI 温控与充电策略改写模块。两条独立链路：

| 链路 | 做法 | 生效时机 | 恢复方式 |
|---|---|---|---|
| 配置改写 | 改写 `/vendor/etc` 下温控 XML、充电曲线、horae 配置的副本，bind mount 覆盖 | 开机早期，挂上即固定 | `umount`，重启自然恢复 |
| 温度伪装 | 守护进程周期性写 `thermal_zone*/emul_temp` 与 `/proc/shell-temp` | boot_completed 之后 | 卸载、`emul_temp` 归零 |

两条链路互不依赖：只挂配置也能降温控，只跑守护也能伪装读数。

- 模块 ID：`quickcharge`
- 数据目录：`/data/adb/quickcharge`
- 构建：`DeepSeek Flash`

---

## 快速开始

```sh
# 看状态
sh /data/adb/modules/quickcharge/action.sh status

# 开启温度伪装（默认参数：42℃ 以下满功率）
sh /data/adb/modules/quickcharge/action.sh temp static
```

安装后**默认只启用配置改写**，运行时伪装是关的（`temp_mode=off`）。
因为温度伪装会改变系统对温度的判断，装完先跑一次确认设备正常，再开伪装更稳妥。

在 Magisk / KSU 管理器里点模块的「操作」按钮，有终端时进入交互菜单。

## 默认策略

```
真实 30~38℃  →  上报 30℃     温差顶满 12℃
真实 39℃      →  上报 33℃
真实 40℃      →  上报 36℃
真实 41℃      →  上报 39℃
真实 ≥42℃     →  关闭模拟，系统读真实值自行降频
```

最后 4℃ 等步长爬升是必要的：从 30 直跳 42 会让系统看到壳温突变 12℃，反而触发一次额外降频。

## 参数

| 参数 | 默认 | 范围 | 作用 |
|---|---|---|---|
| `temp_mode` | `off` | `off` / `static` / `charge` | `static` 全程伪装；`charge` 只在充电且电量低于阈值时伪装 |
| `shell_temp` | 30 | 25~60 | 伪装基准温度（℃） |
| `aggr` | 10 | 0~10 | 暴力程度，可拉开温差 = 2 + aggr |
| `wall` | 42 | 35~80 / `off` | 温度墙，真实温度到此即停止伪装 |
| `battery_limit` | 48 | 30~70 / `off` | 电池哨兵熔断阈值 |
| `sentinel_limit` | 85 | 60~110 / `off` | SoC/主板哨兵熔断阈值 |
| `curr_max` | 0 | 0~8000 | 充电限流（mA），0 = 不限 |
| `curve_offset` | 120 | 0~300 | 充电曲线温度轴右移量，0.1℃ 单位（120 = +12℃） |
| `fast_cap` | 55 | 20~90 | `charge` 模式生效的电量上限（%） |
| `tick` | 15 | 5~300 | 守护周期（秒） |
| `log_level` | 3 | 0~4 | 0 关 / 1 错误 / 2 警告 / 3 信息 / 4 调试 |

任一参数越界都会回落到默认，不会写进系统。

## 命令

```sh
sh action.sh status                 # 状态
sh action.sh temp static 32         # 开启伪装，基准 32℃
sh action.sh temp off               # 关闭伪装
sh action.sh aggr 6                 # 降低暴力程度
sh action.sh wall 45                # 改成 45℃ 收手
sh action.sh curr 3000              # 限流 3A
sh action.sh core 55                # CPU/GPU/DDR 固定报 55℃（独立于 temp 模式）
sh action.sh sentinel 90            # SoC 熔断改 90℃
sh action.sh level 4               # 调试日志
sh action.sh logs e 100             # 最近 100 条错误
sh action.sh logs boot              # 本次开机全过程
sh action.sh rebuild                # 重新生成覆盖层（一般不用，OTA 后开机自处理）
sh action.sh reset                  # 恢复初始状态
```

`logs` 的来源标记：`boot` / `mount` / `override` / `thermal` / `guard` / `charge` / `daemon` / `cmd`。

## 安全设计

**哨兵隔离。** `battery` / `batt*` / `xo-therm` / `xtherm*` 永远不参与伪装，是整个系统里唯一可信的一路读数。把它们一起钉死会让充电 IC 失去温度反馈——这是"充着电死机"的主要来源。

**熔断。** 电池 48℃ / 其他传感器 85℃ 触发时，撤销全部伪装、模式置 `off`、`shell_temp` 清 0。两个阈值可分别关闭。

**渐进让步。** 上报值随真实温度抬高，距墙 4℃ 开始等步长爬升，到墙完全交还。任何分支下上报值都不超过真实温度——超过就成了伪造高温，系统会提前降频。

**参数夹紧。** 伪装值限定 20~100℃，`shell_temp` 25~60℃，非法输入回落默认，绝不把 0℃ 写进传感器。

**开机自救。** 连续 3 次没走到 `service` 阶段就跳过挂载并清空清单。这是不依赖 recovery 的翻车出口。恢复：`sh action.sh reboot-safe` 或重启一次。

**回滚。** `mounts.list` 精确记录每个挂载点；清单丢失时按覆盖层目录反推，只卸确实出现在 `/proc/mounts` 里的路径。卸载后原文件逐字节恢复，`emul_temp` 归零，数据目录删除。

## 配置改写范围

只扫 `/vendor/etc`、`/odm/etc`、`/system/vendor/etc`、`/system/system_ext/etc`、`/vendor/qti/etc`（`-maxdepth 2`），只改这些文件：

| 文件 | 改动 |
|---|---|
| `sys_high_temp_protect_*.xml` | `true` → `false`，阈值不动 |
| `sys_thermal_control_config*.xml` | 开关属性 `true` → `false`，档位数据保留 |
| `thermallevel_to_fps.xml` | `fps` 全部改 144 |
| `sys_thermal_config.xml` | 含 `enable` 的行 `>1<` → `>0<` |
| `devices_config.json` | 充电温度窗口 `150,450]` → `150,550]` |
| `QEGA_Config.txt` | 取样节点 `xo-therm` → `battery` |
| `charging_*.txt` | 温度轴整体 +12℃（可调 `curve_offset`），上限截断 60℃ |
| `horae*.conf` | 置空（空文件比删除安全：SELinux 标签保留） |

**只改属性值，绝不删 XML 节点。** 删节点会留下无主闭标签，产出结构残缺的 XML，thermal HAL 解析失败 → 开机循环。

每个产物落地前校验：开闭标签必须配平、标签总数必须与原件一致、JSON 括号数一致。原件本身不配平则直接拒绝改写。不一致的产物丢弃，宁可不生效也不写坏文件。

OTA 后系统指纹（`ro.build.display.id` + 安全补丁）变化，`post-fs-data` 会自动解挂、重新生成、重新挂载，不需要手动干预。

## 已知限制

- **`curr_max` 只能限流，不能加速。** 充电功率由适配器、协议、电芯内阻决定，改上限无效。真正能提速的是让温度反馈变低（壳温伪装）。
- **`aggr` 在电池哨兵下会饱和。** 受 48℃ 熔断阈值约束，`aggr > 5` 在电池场景下可能达不到理论温差。
- **节点名因机型而异。** `shell-back` / `xo-therm` 这类名字不是所有机型都有；匹配不上时退化为"只挂配置"，日志里会有 `sentinel=none`。
- **SELinux。** `chcon --reference` 失败会汇总成一条 `W` 日志，接着尝试挂载。若系统服务仍拒绝访问，先查这条。
- **只骗得过读 `thermal_zone` 的软件层。** 内核级热保护、硬件断电保护不受影响，这是好事——它是最后一道防线。

## 性能

| 指标 | 数值 |
|---|---|
| 单次 tick（读状态 + 熔断检查 + 决策 + 写入） | 约 3ms |
| 守护 180 秒 CPU 占用（tick=5s） | 20ms |
| 守护常驻内存 | 约 2.2MB |
| `post-fs-data` 冷启动（6 个配置文件） | 约 250ms |
| 停止响应（TERM → 进程退出） | 约 100ms，与 tick 无关 |

实现上做了三件事：

1. **状态走内存缓存。** `state.conf` 用一次 `read` 循环装进变量，tick 内 `sd_state_get` 是纯内建调用，不再逐个 `grep | tail | cut`。
2. **温区表缓存。** `thermal_zone*/type` 只在启动时扫描一次，之后每 40 tick 重扫；tick 内不再读 type 文件。
3. **写入去重。** `emul_temp` 只在目标值变化时才写，避免每 tick 无谓触碰 sysfs。

`sleep "$tick" & wait $!` 而不是直接 `sleep`：`wait` 是内建，收到 TERM 立刻响应，不用等满一个 tick（最长 300 秒）。

## 目录结构

```
quickcharge/
├── module.prop
├── customize.sh        安装：设备检测、生成覆盖层、初始化参数
├── post-fs-data.sh     开机早期：挂载覆盖层，OTA 后自动重建
├── service.sh          开机后期 + 守护进程（--daemon）
├── action.sh           控制入口：CLI + 交互菜单
├── uninstall.sh        卸载：停守护、卸挂载、归零、清数据
├── lib/qc.sh           核心库：配置改写 / 温度伪装 / 充电，单文件
└── META-INF/...
```

`files/` 是安装时生成的覆盖层（不在包里），存放改写后的配置副本，再 bind mount 到系统分区。
如果模块目录只读（元模块放在只读分区），自动回落到 `/data/adb/quickcharge/overrides`。

## 卸载

在管理器里卸载即可。卸载脚本会停守护、卸全部挂载、把 `emul_temp` 写 0、删除数据目录。

想先手动确认：

```sh
sh /data/adb/modules/quickcharge/action.sh umount   # 只卸配置覆盖
grep -c thermal_zone /proc/mounts                   # 应为 0
```

卸载后重启一次最干净。
