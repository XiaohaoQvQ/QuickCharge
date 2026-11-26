# Quick Charge (QC) — shell 版

ColorOS / RealmeUI 的温控与充电策略改写模块。纯 shell 实现，安装即用，不编译、
不依赖二进制，出问题能一行行读、一行行改。

> C 版见独立仓库 [QuickCharge-C](https://github.com/XiaohaoQvQ/QuickCharge-C)：把同一个守护逻辑用 C 重写，每 tick 从 1.3 ms 降到 0.14 ms。
> 两版功能等价，可以随时互换，详见 [第 3 节](#3-与-c-版的对比)。

- 当前版本：`3.1.6`（`versionCode 301601`），C 版为 `3.1.6-c`
- 模块 ID：`quickcharge`
- 数据目录：`/data/adb/quickcharge`
- 适用：Magisk / KernelSU / APatch
- 支持平台：高通、联发科（天玑）、欧加真（OPPO / 一加 / realme）
- 发行版：[全部版本](https://github.com/XiaohaoQvQ/QuickCharge/releases)，命名规则见 [第 14 节](#14-版本与发行版)

---

## 1. 它做两件事

两条**互不依赖**的链路，只开其中一条也能工作：

| 链路 | 做法 | 生效时机 | 恢复方式 |
|---|---|---|---|
| 配置改写 | 改写 `/vendor/etc` 下温控 XML、充电曲线、horae 配置的**副本**，bind mount 覆盖 | 开机早期，挂上即固定 | `umount`，重启自然恢复 |
| 温度伪装 | 守护进程周期性写 `thermal_zone*/emul_temp` 与 `/proc/shell-temp`；没有 `emul_temp` 的温区改用假温度文件 bind 覆盖 `temp` | `boot_completed` 之后 | 卸载、`emul_temp` 归零、解除 bind |

配置改写管的是"系统以为自己在什么条件下该降频"，温度伪装管的是"系统以为现在多少度"。
前者是静态的、开机定死；后者是动态的，3.1.0 起**恒定**上报同一个值——不看真实读数，
插着电就一直让系统以为电池很凉。

原始文件一律备份，从不直接改。`uninstall.sh` 会逐项还原。

---

## 2. 为什么还用 shell

这个守护进程每 15 秒读几十个 sysfs 小文件、算一遍目标、偶尔写几个节点。
用 shell 写它有实打实的代价（每轮 4 次 fork、1.3 ms），但换来三件事：

**能读。** 全部逻辑在 `lib/qc.sh` 一个文件里，4116 行，没有编译产物。想知道"为什么
我的手机没效果"，`grep` 一下就能找到判定分支。

**能改。** 现场发现某个机型的温区名字不一样，改一行正则、`action.sh restart` 就生效。
不用装交叉编译器，不用重新打包。

**能自救。** 脚本某一行报错，循环会继续跑下一轮；C 版一处越界就是段错误，整个守护没了。
这是 `service.sh` 保留 shell 回退路径的根本原因。

代价也很明确，见 [第 10 节](#10-已知限制)。

---

## 3. 与 C 版的对比

同一个版本号，两个包，功能等价，守护实现不同。下表数字实测于 2.9.42 / 2.9.43 / 2.9.44，
之后的版本沿用同一套热路径，量级没有变化。

| 指标 | 2.9.42 | **shell 现行** | C 现行 |
|---|---|---|---|
| 每 tick CPU | 9.4 ms | **1.3 ms** | 0.14 ms |
| 每 tick fork | 41 | **4（首轮后 1）** | 0 |
| 常驻内存 RSS | 3 到 5 MB | **3 到 5 MB** | 988 KB |
| 日均 CPU（tick=15s） | 约 54 秒 | **约 7 秒** | 约 1 秒 |
| 包体积 | 67 KB | **80 KB** | 406 KB |
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

两个包共用同一份 `service.sh`，靠 `module.prop` 的 `channel` 区分：`channel=c` 才会
`exec bin/qcmon`，`channel=shell` 一律走 shell 循环。所以可以随时换包刷入，参数和日志都不丢。

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

### 4.1 面板

模块带 `webroot/index.html`，在 **KernelSU / KsuWebUI / MMRL** 里点模块的「打开」即可。
纯静态页面，命令走管理器的 `ksu.exec`，与命令行完全一致，改完立即生效。

从上到下十张卡：

| 卡片 | 内容 |
|---|---|
| 实时状态 | 真实 / 系统看到 / 配置 / 守护 四格，下面一行结论文案 |
| 实时功耗 | 电流、功率、电池温度，附一条只在页面打开时采样的曲线 |
| 温控改写范围 | 全局运行 / 仅充电 / 关闭 三个按钮 |
| 核心参数 | 只留一个「伪装温度」滑块（20 到 33℃），恒定上报 |
| 极限功率 | 电池 NTC 伪装、取消阶梯限流、CPU 伪装 |
| 刷新率 | 6 格滑块 + 强制锁定 |
| 诊断日志 | 关闭 / 详细 两个按钮，点详细才开日志 |
| 操作 | 刷新 / 重挂 / 重启守护 三个按钮一行 |

状态卡那行结论只给数字关系，不给形容词：`真实 41℃ → 系统看到 25℃`、
`恒定 25℃ · 不看真实温度`、`待机中 · 插电后接管`、`写入失败 · 系统仍读真实温度`。
两个数不一样就是在骗系统，一样就是没改写。

**模块描述页也会显示状态**。管理器模块列表里那一行 `description` 由守护同步，三种写法：

| 场景 | 显示 |
|---|---|
| 正常运行 | `✅ 运行中 · 温度伪装 25℃ · 高刷 120Hz · 配置 9 项` |
| 刚装完 / 刚更新 | `❌ 请重启 · 重启后开始工作` |
| 没运行 / 卡死 | `❌ 未运行 · 把 /data/adb/quickcharge/ 的日志发给作者` |

用 ✅ / ❌ 而不是给文字上色，是因为管理器把 `description` 当纯文本渲染，不解析 HTML 标签。

---

## 5. 三种温度模式

| 模式 | 行为 | 适合 |
|---|---|---|
| `off` | 完全不伪装，只保留配置改写 | 想验证配置改写本身是否生效 |
| `charge` | **仅插电时**伪装，拔电还原真实读数 | 默认，日常使用 |
| `static` | 一直伪装到 `shell_temp`（默认 25℃） | 游戏、长时间高负载 |

`charge` 是默认值，也是最"无感"的：温度只在充电时被改写，平时系统看到的是真实值，
不会影响调度和风扇策略。

两种模式伪装时都写**同一个恒定值**：不跟真实温度走、不设温度墙、不设熔断线、
不按电量退出。想让系统以为电池更凉，就把 `shell_temp` 往下调（最低 20℃——再低
不少平台会把 NTC 判成开路，反而锁 5V/500mA）。

---

## 6. 参数

全部存在 `/data/adb/quickcharge/state.conf`，纯 `key=value`。改完执行 `action.sh restart`
立即生效，不用重启手机。

| 参数 | 默认 | 范围 | 说明 |
|---|---|---|---|
| `temp_mode` | `charge` | off / charge / static | 温度模式 |
| `shell_temp` | `25` | 20 到 33 | 伪装温度（恒定上报这个值） |
| `core_temp` | `off` | off / 20 到 100 | CPU / GPU / DDR 固定伪装 |
| `noncore_temp` | `off` | off / 20 到 100 | 其它温区固定伪装 |
| `hz` | `off` | 60 到 185 / off | 刷新率 |
| `tick` | `15` | 5 到 300 | 守护轮询间隔（秒） |
| `log_level` | `1` | 0 到 4 | 0 只留 E / 1 事件（默认）/ 2 事件+快照 / 3 逐轮 / 4 调试 |
| `chg_unlock` | `0` | 0 / 1 | 充电阶梯解锁：HAL 节点写 0，不按温度撤销 |
| `curve_offset` | `120` | 0 到 300 | 充电曲线偏移，0.1℃ 单位（120 = +12℃） |
| `power_scale` | `100` | 50 到 200 | 电流读数校准 % |
| `cells_mode` | `auto` | auto / 1 / 2 | 电芯数 |

`wall`、`aggr`、`curr_max`、`curr_edge`、`fast_cap`、`battery_limit`、`sentinel_limit`、
`cool_guard` 这八个键在 3.1.0 全部删除，升级时由 `customize.sh` 从 `state.conf` 里清掉；
真机残留也无害，守护不再读它们。

`log_level` 从 2.9.68 起默认 1：0 只留错误，安装、守护启停这些关键事件全是 `I`，
设成 0 会让日志面板看起来是空的。

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
| `env` | 打印最近 4 条环境头（机型 / ROM / 内核 / 版本） |
| `diag [秒] [间隔]` | 现场诊断采样，默认 120s / 2s，排查掉功率用 |

**温度**

| 命令 | 作用 |
|---|---|
| `temp <off\|static\|charge> [℃]` | 温度模式 |
| `shell <℃\|off>` | 等同 `temp static` |
| `core <off\|20-100>` | CPU / GPU / DDR 固定伪装 |
| `noncore <off\|20-100>` | 其它温区固定伪装 |
| `batt <off\|20-45>` | 电池 NTC 伪装（不按真实温度撤销） |
| `base <20-33>` | 只改伪装温度，不切模式 |

**充电**

| 命令 | 作用 |
|---|---|
| `pscale <50-200>` | 电流读数校准 % |
| `cells <auto\|1\|2>` | 电芯数 |
| `chg` / `snap` | 打印 / 记录一条充电现场 |

**显示与系统**

| 命令 | 作用 |
|---|---|
| `hz <60-185\|off> [soft\|hard]` | 刷新率，`hard` 额外锁定内容帧率匹配 |
| `hzguard <on\|off>` | 强制锁定开关（档位不变，只切力度） |
| `unlock <on\|off>` | 取消充电阶梯限流（`charge_control_limit` / `thermal_charging` 写 0，原值备份，不按温度撤销） |
| `tiers` | 充电阶梯诊断：列出 `charge_control_limit`、`thermal_charging`、`cool_down` 等节点与当前值 |
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

欧加真（ColorOS / RealmeUI）额外有 `ignore_screen_state` 开关，找不到就跳过，
不报错、不影响其它功能。

充电的「阶梯」由系统 thermal HAL 写 `charge_control_limit` / `thermal_charging`，
以及充电驱动按电池温度自己分档（欧加是 `oplus_chg/battery/cool_down`）。
想知道本机谁在限流，跑 `action.sh tiers`；要解除 HAL 侧限制，用 `action.sh unlock on`。
3.0.8 删掉了原来的 `thermal` / `horae` 开关：它只管 CPU/GPU 降频与亮度，
跟充电毫无关系，留着只会让人以为能解决掉功率。

不确定自己机器支持哪些，直接跑：

```sh
sh /data/adb/modules/quickcharge/action.sh check
```

---

## 9. 极速模式：没有兜底

3.1.0 起这个模块**只追求充电速度**，不再做任何安全让步：

- 没有熔断。电池 50℃、主板 90℃ 都照常伪装，不会自动停手、不会自动还原。
- 没有温度墙。真实温度多高都不影响上报值。
- 没有电量阈值。充到 100% 也继续伪装，不交还系统。
- 没有绝对电流墙，没有温差档位。电流怎么走由系统和驱动决定。

**这意味着热失控的最后一道防线只剩系统和电芯自己的保护板。** 充电时请自己摸一下
机身温度；发烫就拔线，或者 `action.sh temp off` 停掉伪装。这不是免责声明，是使用方式。

剩下的只有这些"不牺牲速度的前提下顺手做对"的事：

**范围校验。** 伪装温度必须落在 20 到 33℃ 之间。下限是硬性的：再低不少平台会把
NTC 判成开路，直接锁 5V/500mA，反而更慢。

**降流解除带电流闸。** `cool_down` 非 0 且实测电流 < 2.5A 时才写 0。已经满速时
不碰这个节点——写入本身会让 OPlus 重选档，实测 4.3A 时写一下就从 32W 掉到 6W。

**退出还原。** 三种退出路径（正常退出、`uninstall.sh`、`restart`）都会：`emul_temp` 归零、
`umount` 覆盖层、删除临时文件、阶梯解锁的原值写回。

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
4. **`charge` 模式拔电后最长要等一轮 `tick` 才还原真实读数**。
5. **屏幕快充只能改写节点**。厂商驱动在 `fb_notifier` 里压 FCC（亮屏压到 1500 到 2000mA，
   约 7 到 9W）时，模块靠 `ignore_screen_state` 或回写 FCC 顶回去；回写只在亮屏做，
   息屏完全交还驱动（息屏是驱动放开 FCC 的窗口，这时写反而会压住功率）；
   节点全部只读、或系统在息屏后另有服务压流，就只能认。电量 80% 以上进入恒压，
   电流本来就会往下掉，这部分不是模块能拉回来的。
6. **不保证所有机型**。`check` 给出的是"这台机器能用什么"，不是"一定能降温"。

---

## 11. 目录结构

```
quickcharge/
├── module.prop           模块信息（description 由守护同步成三态状态 + 摘要）
├── customize.sh          安装：设备检测、生成覆盖层、初始化参数、写 need_reboot
├── post-fs-data.sh       开机早期：备份原文件、挂载覆盖层，OTA 后自动重建
├── service.sh            开机后期启动守护；channel=c 且带 bin/qcmon 才交给 C 版
├── action.sh             控制入口：CLI 与交互菜单，601 行
├── uninstall.sh          卸载：停守护、卸挂载、归零、清数据
├── lib/qc.sh             核心库，4116 行，全部逻辑在这里
├── webroot/index.html    WebUI（纯静态，KernelSU / MMRL / KsuWebUI 加载）
├── src/qcmon.c           C 版源码（2711 行，仅仓库内、不打包，已拆到 QuickCharge-C）
├── docs/TECH.md          设计细节与踩过的坑（不打包）
├── tests/                冒烟测试：c-test / chg-unit / cool-unit / state-unit / sim
└── META-INF/...
```

想理解某条策略为什么这样定，直接读 `lib/qc.sh`。函数名统一 `sd_` 前缀，按功能分段，
`grep "^sd_" lib/qc.sh` 就能列出全部入口。

---

## 12. 卸载

在管理器里卸载模块即可，或者：

```sh
su 0 sh -c 'sh /data/adb/modules/quickcharge/uninstall.sh'
```

会依次停守护、卸挂载、`emul_temp` 归零、还原备份文件、删除 `/dev/qc` 与数据目录。
不放心就重启一次，所有改动都在内存里，重启必然复原。

---

## 13. 许可

源码完全公开，**禁止商用与非法用途**。

改写温控与充电策略存在硬件风险，使用者自行承担后果。上机前建议先跑
`action.sh check` 确认功能可用，再逐项开启。

---

## 14. 版本与发行版

两个仓库各自独立发版，同一个功能改动同步提交：

| 仓库 | 当前版本 | 包名 | versionCode |
|---|---|---|---|
| [QuickCharge](https://github.com/XiaohaoQvQ/QuickCharge)（shell） | `3.1.6` | `QuickCharge-v3.1.6.zip` | 301601 |
| [QuickCharge-C](https://github.com/XiaohaoQvQ/QuickCharge-C)（C 守护） | `3.1.6-c` | `QuickCharge-v3.1.6-c.zip` | 301600 |

每个仓库的 Release 只附自己那一份模块包，装哪个版本就去哪个仓库下载，不会混。

发行版标题统一为「产品全名 + 版本号」，不带摘要：

```
Quick Charge v3.1.6
Quick Charge v3.1.6-c
```

tag 与标题一致：shell 仓 `v3.1.6`，C 仓 `3.1.6-c`。历史发行版从 2.9.49 起全部按这个规则重建过，
更早的版本只统一了标题，正文保持原样。

### 版本号规则（3.0 起）

版本固定三段 `主.次.修订`：

- 修 bug / 小改动：修订 +1（`3.0.1`、`3.0.12` …）；
- 删功能 / 改语义：次版本 +1（`3.1.0`：安全保护整套删除）；
- **修订到 100 进一位**：`3.0.100` 的下一个版本是 `3.1.0`；
- 功能线变更：次版本 +1，修订归零。

`versionCode` 按 `(主×100 + 次)×1000 + 修订×2 + 通道` 计算，通道 1 = shell、0 = C，
两个包始终一奇一偶、严格递增。例：`3.0.0` → shell `300001` / C `300000`，
`3.0.100` → `300201` / `300200`，`3.1.0` → `301001` / `301000`。

`versionCode` 是管理器判新旧的唯一依据，shell 版为奇数序列、C 版为偶数序列，两者互不覆盖。

### 在线升级

模块自带更新检查，管理器里能直接看到「更新」按钮，点一下自动下载安装，不用再手动找包。

`module.prop` 里多一行 `updateJson`，指向仓库根目录的 `update.json`：

```properties
updateJson=https://github.com/XiaohaoQvQ/QuickCharge/releases/latest/download/update.json
```

`update.json` 只有四个字段，`versionCode` 是唯一参与比较的数字，必须与 `module.prop` 的
`versionCode` 一致、且随版本严格递增：

```json
{
  "version": "3.1.6",
  "versionCode": 301601,
  "zipUrl": "https://github.com/XiaohaoQvQ/QuickCharge/releases/download/v3.1.6/QuickCharge-v3.1.6.zip",
  "changelog": "https://github.com/XiaohaoQvQ/QuickCharge/releases/latest/download/RELEASE.md"
}
```

- `updateJson` 用 Release 的 `latest/download/` 直链，**每次发版必须把 `update.json` 一起作为资产上传**，
  它靠 GitHub 的 `latest` 重定向指向最新一版，没有 CDN 缓存，发完立刻生效；
- 不用 jsDelivr：`@main` 分支缓存 12 小时且不能 purge，发版后一整天收不到提示；
- `changelog` 同理，用 `latest/download/RELEASE.md`，每次发版一并上传；
- 两个仓库各自维护一份，C 版指 C 仓，否则 shell 用户会被提示装 C 版。

发版流程因此多一步：改 `module.prop` 的 `version` / `versionCode` 之后，同步改 `update.json`
的同名两个字段，否则升级提示会落后一个版本。

> **字段名必须是 `versionCode`，中间那个 C 要大写。** `module.prop` 是按行原样解析的键值对，
> 管理器读的是驼峰 `versionCode`；写成全小写 `versioncode` 不会报错，但本地版本号会被读成
> `0`，于是远端任何版本都比它大，模块卡片上的「更新」按钮就再也消不掉——装到最新也一样。
> 3.0.2 及更早的包踩过这个坑，3.0.3 起已改为驼峰。

---

## 附录：设计细节

本文只讲怎么用。想看每条策略为什么这么定——配置改写的具体范围、温区分类规则、
温度伪装的取值边界、平台差异（高通 / MTK / 欧加真）、各版本踩过的坑，
见 [docs/TECH.md](docs/TECH.md)。
