# Quick Charge (QC) — shell 版

ColorOS / RealmeUI 的温控与充电策略改写模块。纯 shell 实现，安装即用，不编译、
不依赖二进制，出问题能一行行读、一行行改。

> C 版见同目录 `README-c.md`（独立仓库 qcmon）：把同一个守护逻辑用 C 重写，每 tick 从 1.3 ms 降到 0.14 ms。
> 两版功能等价，可以随时互换，详见 [第 3 节](#3-与-c-版的对比)。

- 模块 ID：`quickcharge`
- 数据目录：`/data/adb/quickcharge`
- 适用：Magisk / KernelSU / APatch
- 支持平台：高通、联发科（天玑）、欧加真（OPPO / 一加 / realme）

---

## 1. 它做两件事

两条**互不依赖**的链路，只开其中一条也能工作：

| 链路 | 做法 | 生效时机 | 恢复方式 |
|---|---|---|---|
| 配置改写 | 改写 `/vendor/etc` 下温控 XML、充电曲线、horae 配置的**副本**，bind mount 覆盖 | 开机早期，挂上即固定 | `umount`，重启自然恢复 |
| 温度伪装 | 守护进程周期性写 `thermal_zone*/emul_temp` 与 `/proc/shell-temp`；没有 `emul_temp` 的温区改用假温度文件 bind 覆盖 `temp` | `boot_completed` 之后 | 卸载、`emul_temp` 归零、解除 bind |

配置改写管的是"系统以为自己在什么条件下该降频"，温度伪装管的是"系统以为现在多少度"。
前者是静态的、开机定死；后者是动态的、每 15 秒跟着真实温度走。

原始文件一律备份，从不直接改。`uninstall.sh` 会逐项还原。

---

## 2. 为什么还用 shell

这个守护进程每 15 秒读几十个 sysfs 小文件、算一遍目标、偶尔写几个节点。
用 shell 写它有实打实的代价（每轮 4 次 fork、1.3 ms），但换来三件事：

**能读。** 全部逻辑在 `lib/qc.sh` 一个文件里，3390 行，没有编译产物。想知道"为什么
我的手机没效果"，`grep` 一下就能找到判定分支。

**能改。** 现场发现某个机型的温区名字不一样，改一行正则、`action.sh restart` 就生效。
不用装交叉编译器，不用重新打包。

**能自救。** 脚本某一行报错，循环会继续跑下一轮；C 版一处越界就是段错误，整个守护没了。
这是 `service.sh` 保留 shell 回退路径的根本原因。

代价也很明确，见 [第 10 节](#10-已知限制)。

---

## 3. 与 C 版的对比

同一个版本号，两个包，功能等价，守护实现不同。

| 指标 | 2.9.42 | **2.9.43 shell** | 2.9.44 C |
|---|---|---|---|
| 每 tick CPU | 9.4 ms | **1.3 ms** | 0.14 ms |
| 每 tick fork | 41 | **4（首轮后 1）** | 0 |
| 常驻内存 RSS | 3~5 MB | **3~5 MB** | 988 KB |
| 日均 CPU（tick=15s） | 约 54 秒 | **约 7 秒** | 约 1 秒 |
| 包体积 | 67 KB | **67 KB** | 390 KB |
| 改一行要做什么 | 存盘 | **存盘 + restart** | 改 C 源码 + 交叉编译 + 打包 |

2.9.43 这一版对 shell 本身做了两处优化，41 次 fork 降到 4 次：

```sh
# 优化前：两次 fork，一次 cat 一次 tr
temp=$(cat "$zone/temp" | tr -d ' \t\r\n')

# 优化后：零次 fork，read 是 shell 内建
read -r temp < "$zone/temp"
```

实测 2400 次读取从 1325 ms 降到 13 ms。这类优化与语言无关，只要肯改就能拿到。

**该选哪个：**

- 日常使用，**shell 版就够**。7 秒/天的 CPU 差异在手机上不可感知，换来的是随时能改。
- 老机型、极度在意唤醒开销、或 shell 版 fork 太频繁被内核 cgroup 记录异常，用 C 版。

两个包共用同一份 `service.sh`：检测到 `bin/qcmon` 就 `exec` 它，没有就走 shell 循环。
所以可以随时换包刷入，参数和日志都不丢。

---

## 4. 快速开始

```sh
# 看状态
sh /data/adb/modules/quickcharge/action.sh status

# 看这台机器能用哪些功能（一次采样，直接给结论）
sh /data/adb/modules/quickcharge/action.sh check

# 改成全场景生效（默认是「仅充电」）
sh /data/adb/modules/quickcharge/action.sh temp static

# 完全关掉
sh /data/adb/modules/quickcharge/action.sh temp off
```

安装后**默认就是「仅充电」自动生效**（`temp_mode=charge`），不需要任何手动操作。
重启完成后守护自己接管，插电且电量低于 `fast_cap` 时改写，拔电后还原真实读数。

在 KernelSU / APatch 管理器里点模块的「操作」按钮会进入交互菜单；在终端里执行
`action.sh` 不带参数则打印状态（管理器里没有终端，进不了菜单）。

---

## 5. 三种温度模式

| 模式 | 行为 | 适合 |
|---|---|---|
| `off` | 完全不伪装，只保留配置改写 | 想验证配置改写本身是否生效 |
| `charge` | **仅插电时**伪装，拔电还原真实读数 | 默认，日常使用 |
| `static` | 一直伪装到 `shell_temp`（默认 30℃） | 游戏、长时间高负载 |

`charge` 是默认值，也是最"无感"的：温度只在充电时被改写，平时系统看到的是真实值，
不会影响调度和风扇策略。

---

## 6. 参数

全部存在 `/data/adb/quickcharge/state.conf`，纯 `key=value`。改完执行 `action.sh restart`
立即生效，不用重启手机。

| 参数 | 默认 | 范围 | 说明 |
|---|---|---|---|
| `temp_mode` | `charge` | off / charge / static | 温度模式 |
| `shell_temp` | `30` | 25~60 | `static` 模式的目标壳温 |
| `core_temp` | `off` | off / 20~100 | CPU / GPU / DDR 固定伪装 |
| `noncore_temp` | `off` | off / 20~100 | 其它温区固定伪装 |
| `wall` | `42` | 35~80 | 温度墙：真实温度到此停止伪装 |
| `aggr` | `10` | 0~10 | 温控档位，越高越激进（CLI 里叫 `gear`） |
| `curr_max` | `0` | 0 / 300~8000 | 充电限流 mA，0 = 不限 |
| `curr_edge` | `4` | 0~6 | 距墙几度开始降流，0 = 顶到墙才降 |
| `fast_cap` | `55` | 20~90 | 快充生效的电量阈值 % |
| `battery_limit` | `48` | 30~70 | 电池哨兵熔断阈值 ℃ |
| `sentinel_limit` | `85` | 60~110 | SoC / 主板哨兵熔断阈值 ℃ |
| `hz` | `off` | 60~185 / off | 刷新率 |
| `tick` | `15` | 5~300 | 守护轮询间隔（秒），`charge` 模式固定 10s 不受它影响 |
| `log_level` | `3` | 0~4 | 0 关 / 1 E / 2 W / 3 I / 4 D |
| `horae` | `1` | 0 / 1 | OPPO 热管理服务开关 |
| `curve_offset` | `120` | — | 充电曲线偏移 |
| `power_scale` | `100` | 50~200 | 电流读数校准 % |
| `cells_mode` | `auto` | auto / 1 / 2 | 电芯数 |

`curr_edge` 不在初始文件里，代码里兜底为 4，写进去才生效。

---

## 7. 命令

```sh
ACTION=/data/adb/modules/quickcharge/action.sh
```

**状态与诊断**

| 命令 | 作用 |
|---|---|
| `status` | 当前状态 |
| `json` | 机器可读状态，WebUI 用 |
| `probe` | 温度读取自检（温区 / 电池节点 / 缓存 / 决策现场） |
| `zones` | 温区判定全表：type / 语义类 / 是否 core 候选 |
| `check` | 适配检查：一次采样，直接给出能用哪些功能 |
| `diag [秒] [间隔]` | 现场诊断采样，默认 120s / 2s，排查掉功率用 |

**温度**

| 命令 | 作用 |
|---|---|
| `temp <off\|static\|charge> [℃]` | 温度模式 |
| `shell <℃\|off>` | 等同 `temp static` |
| `core <off\|20-100>` | CPU / GPU / DDR 固定伪装 |
| `noncore <off\|20-100>` | 其它温区固定伪装 |
| `batt <off\|20-45>` | 电池 NTC 伪装（真实 ≥46℃ 自动撤销并冷却 120s） |
| `gear <0-10>` | 温控档位，`aggr` 为旧名 |
| `base <25-60>` | 只改基准温度，不切模式 |
| `wall <35-80\|off>` | 温度墙 |

**充电**

| 命令 | 作用 |
|---|---|
| `curr <300-8000\|off>` | 充电限流 mA，按温度联动降流 |
| `curredge <0-6>` | 距墙几度开始降流 |
| `fast <20-90>` | 快充生效电量阈值 % |
| `sentinel <60-110\|off>` | SoC / 主板熔断阈值 |
| `battery <30-70\|off>` | 电池熔断阈值 |
| `boost <on\|off>` | 暴力模式：顶墙才降流 + 档位 10 + 快充阈值 85% |
| `pscale <50-200>` | 电流读数校准 % |
| `cells <auto\|1\|2>` | 电芯数 |

**显示与系统**

| 命令 | 作用 |
|---|---|
| `hz <60-185\|off> [soft\|hard]` | 刷新率，`hard` 额外锁定内容帧率匹配 |
| `hzguard <on\|off>` | 强制锁定开关（档位不变，只切力度） |
| `thermal <on\|off>` / `horae <0\|1>` | 系统热管理总开关 |
| `power` | 电流 / 电压 / 功率读数（JSON） |
| `level <0-4>` | 日志级别 |
| `logs [e\|w\|i\|d\|boot\|daemon\|N]` | 查看日志 |

**维护**

| 命令 | 作用 |
|---|---|
| `mount` / `umount` | 手动挂载 / 卸载配置覆盖层 |
| `rebuild` | 重新生成并挂载（OTA 后一般不用） |
| `reboot-safe` | 退出安全模式并立即重挂 |
| `restart` | 重启守护进程，改完参数强制生效 |
| `reset` | 恢复初始状态，清空全部参数 |
| `menu` | 交互菜单（需要真终端） |

---

## 8. 平台适配

高通和联发科用**同一套判断逻辑**，差异集中在三处，都在 `lib/qc.sh` 里集中处理：

| 差异点 | 高通 | 联发科 | 处理方式 |
|---|---|---|---|
| 温区命名 | `cpu-0-0`、`gpu-0-0` | `cpu_therm`、`gpu_therm` | 正则同时匹配，扫一次缓存 |
| 电流单位 | 多为 µA | 多为 mA | 读原始文本判断量级，回写保留原单位 |
| 充电节点 | `oplus_chg` | `mtk_charger` / `charger` | 多个候选路径依次尝试 |

欧加真（ColorOS / RealmeUI）额外有 `horae` 热管理服务和 `ignore_screen_state` 开关，
两者都是可选路径：找不到就跳过，不报错、不影响其它功能。

不确定自己机器支持哪些，直接跑：

```sh
sh /data/adb/modules/quickcharge/action.sh check
```

---

## 9. 安全设计

这个模块会改温度读数，做错会伤硬件，所以有几层兜底：

**熔断。** 守护每轮读一个"哨兵"温区（默认 SoC / 主板，阈值 85℃；电池单独阈值 48℃）。
一旦实测超过阈值，立刻暂停所有伪装、撤销已写入的值，并记日志。温度回落到阈值下 3℃
并持续一轮后自动恢复。熔断期间不会反复写入，也不会改写配置——只是停手。

**范围校验。** 所有伪装值必须落在 20~100℃ 之间，电池伪装上限 45℃，超出直接拒绝。

**退出还原。** 三种退出路径（正常退出、`uninstall.sh`、`restart`）都会：`emul_temp` 归零、
`umount` 覆盖层、删除临时文件。

**临时文件不落 `/data/adb`。** 伪装用的假温度文件放在 `/dev/qc`（tmpfs）。原因是
`/data/adb` 下的 bind 源路径会出现在 mountinfo 里，普通 App 也能读到挂载表；
换到 tmpfs 后那条记录只剩 `tmpfs /qc/xxx.temp`。目录 700、文件 644——读方不一定是 root，
收紧到 600 会让伪装"成功但没人读到"。`/dev` 重启即清，卸载脚本也会删目录。
落点不可写时回退到 `/data/adb/quickcharge/run`，功能不变。

**备份。** 所有被改写的原始文件在 `post-fs-data.sh` 里备份，还原时逐项比对，从不盲写。

---

## 10. 已知限制

1. **每次 fork 有成本**。1.3 ms/tick、4 次 fork，比 C 版高一个数量级。tick=15s 时
   日均 CPU 约 7 秒，可接受但不为零。
2. **温区命名靠正则猜**。厂商改个名字就可能漏判。用 `action.sh zones` 能立刻看出
   哪些温区没被识别。
3. **配置改写依赖具体路径**。ColorOS 大版本升级可能换目录结构。OTA 后 `post-fs-data.sh`
   会自动重建覆盖层，但路径全变了就得改代码。
4. **`charge` 模式轮询固定 10 秒**（不受 `tick` 影响），所以拔电后最长要等一轮才还原真实读数。
5. **不支持内核级接管**。如果厂商驱动在 `fb_notifier` 里硬压 FCC（亮屏压到 1500~2000mA，
   约 7~9W），shell 层只能尽量改写节点，改不动的地方只能认。
6. **不保证所有机型**。`check` 给出的是"这台机器能用什么"，不是"一定能降温"。

---

## 11. 目录结构

```
quickcharge/
├── module.prop           模块信息（描述会被守护同步成实时状态）
├── customize.sh          安装：设备检测、生成覆盖层、初始化参数
├── post-fs-data.sh       开机早期：备份原文件、挂载覆盖层，OTA 后自动重建
├── service.sh            开机后期启动守护；检测到 bin/qcmon 则交给 C 版
├── action.sh             控制入口：CLI 与交互菜单
├── uninstall.sh          卸载：停守护、卸挂载、归零、清数据
├── lib/qc.sh             核心库，3390 行，全部逻辑在这里
├── webroot/index.html    WebUI（纯静态，KernelSU / MMRL / KsuWebUI 加载）
├── src/qcmon.c           C 版源码（2239 行，仅仓库内，不打包）
├── bin/qcmon             C 版二进制（仅 C 版包携带）
├── tests/                冒烟测试（仅仓库内）
└── META-INF/...
```

想理解某条策略为什么这样定，直接读 `lib/qc.sh`。函数名统一 `sd_` 前缀，按功能分段，
`grep "^sd_" lib/qc.sh` 就能列出全部入口。

---

## 12. 卸载

在管理器里卸载模块即可，或者：

```sh
su -c 'sh /data/adb/modules/quickcharge/uninstall.sh'
```

会依次停守护、卸挂载、`emul_temp` 归零、还原备份文件、删除 `/dev/qc` 与数据目录。
不放心就重启一次，所有改动都在内存里，重启必然复原。

---

## 13. 许可

源码完全公开，**禁止商用与非法用途**。

改写温控与充电策略存在硬件风险，使用者自行承担后果。上机前建议先跑
`action.sh check` 确认功能可用，再逐项开启。
