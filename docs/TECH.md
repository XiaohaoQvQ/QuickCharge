# Quick Charge 设计细节

> 快速上手、参数表、常用命令看仓库首页 [README](../README.md)。本文讲内部实现与取舍。

ColorOS / RealmeUI 温控与充电策略改写模块，高通与联发科（天玑）平台使用同一套判断，
差异部分见 [平台适配](#平台适配高通--mtk--欧加真)。两条独立链路：

| 链路 | 做法 | 生效时机 | 恢复方式 |
|---|---|---|---|
| 配置改写 | 改写 `/vendor/etc` 下温控 XML、充电曲线、horae 配置的副本，bind mount 覆盖 | 开机早期，挂上即固定 | `umount`，重启自然恢复 |
| 温度伪装 | 守护进程周期性写 `thermal_zone*/emul_temp` 与 `/proc/shell-temp`；没有 `emul_temp` 的温区改用假温度文件 bind 覆盖 `temp` | boot_completed 之后 | 卸载、`emul_temp` 归零、解除 bind |

两条链路互不依赖：只挂配置也能降温控，只跑守护也能伪装读数。

伪装用的临时文件落在 `/dev/qc`（tmpfs）。bind 之后 mountinfo 的第 4 段就是源路径，
放在 `/data/adb` 下等于把 root 目录写进普通 App 也能读到的挂载表；换到 tmpfs 后那条
记录变成 `tmpfs /qc/xxx.temp`。目录 700、文件 644（读方不一定是 root，收紧到 600
会让伪装"成功但没人读到"）。`/dev` 重启即清，卸载脚本也会删目录。落点不可写时
回退到 `/data/adb/quickcharge/run`，功能不变，痕迹回到旧样子。

- 模块 ID：`quickcharge`
- 数据目录：`/data/adb/quickcharge`
- 作者：Xiaohao ｜ QQ 群：[点击链接加入群聊【Quick Charge】](https://qun.qq.com/universal-share/share?ac=1&authKey=sxretTuuUbT6DSq6WUsRcAhqpzEtEmLdUgjcJW5EFkih769NPI7mFOtBWBsiLb56&busi_data=eyJncm91cENvZGUiOiIxMDAzNDgxNjYwIiwidG9rZW4iOiJnaGZRMVVNSCtOZFNyWUV4cEk2bU9Jd05neVpwUmVkOTIxV3VpcVRwS2Iram1rNC81TmtnNUJ3MjRxYm9JcGJEIiwidWluIjoiMjExMTgzNTIyMCJ9&data=Gr9CwynFwy41T0Lgv3epv7_E3bgXVe1lKsqwWOnF338a3I7veanebrcFNu2aJI8_5AZAHr7NXTdhgkf2iFtq-g&svctype=4&tempid=h5_group_info) ｜ 酷安：[关注作者](https://www.coolapk.com/u/27316679)
- 本文件只用于仓库展示，不打包进模块 zip

---

## 快速开始

```sh
# 看状态
sh /data/adb/modules/quickcharge/action.sh status

# 改成全场景生效（默认是「仅充电」）
sh /data/adb/modules/quickcharge/action.sh temp static

# 完全关掉
sh /data/adb/modules/quickcharge/action.sh temp off
```

安装后**默认就是「仅充电」自动生效**（`temp_mode=charge`），不需要任何手动操作：
重启完成后守护自己接管，插电就改写（不看电量），拔电一轮内还原真实读数。

只有充电这一个场景会动温控，日常使用（打游戏、待机）不碰。想更激进选「全局运行」，
想完全不改写在面板点「关闭」——手动关过之后，升级不会再把它重新打开。

在 Magisk / KSU 管理器里点模块的「操作」按钮，有终端时进入交互菜单。

## 两个发行版

同一个版本号，两个包，功能一致，守护实现不同：

| | `QuickCharge-v2.9.45.zip` | `QuickCharge-v2.9.45-c.zip` |
|---|---|---|
| 守护 | `lib/qc.sh` + shell 循环 | `bin/qcmon`（C，静态 arm64） |
| 每 tick | 1.3 ms / 4 次 fork（首轮后 1 次） | 0.1-0.2 ms / 0 次 fork |
| 常驻内存 | 3-5 MB | < 1 MB |
| 包体积 | 80 KB | 406 KB（内含 713 KB 静态二进制） |
| 适用 | 任何机型，出问题容易用 `sh -x` 追 | 追求零唤醒开销、老机型 |

C 版把 `bin/qcmon` 放进包里，并在 `module.prop` 写 `channel=c`，`service.sh` 只有看到
这个标记才 `exec`，不再走 shell 循环；shell 包不含二进制、写 `channel=shell`。
二进制不存在或跑不起来（架构不对、被杀软拦）会自动回退 shell 版，所以两个包
共用同一份 `service.sh`。

> 3.1.2～3.1.3 的 shell 包误带了二进制，`service.sh` 只看「文件在不在」，
> 导致 shell 版实际跑的是 C 守护——shell 侧的修复对这批用户完全没生效。
> 3.1.4 起改为显式通道判定，残留的二进制一律不碰。

想临时验证 shell 版行为，不用重刷：

```sh
su 0 sh -c 'SD_SHELL_DAEMON=1 sh /data/adb/modules/quickcharge/service.sh'
```

**两个版本覆盖同一套热路径**，可以随时互换（`state.conf`、`run/` 下的状态文件、
日志格式都通用）：

- 温区扫描与分类，作用域（core / noncore / batt）判定与兜底
- 壳温恒定额上报：`emul_temp` 与 `/proc/shell-temp` 双落点，与真实读数无关
- 核心 / 非核心温度伪装（bind mount），稳态下不重复挂载
- 屏幕快充：内核 `ignore_screen_state` 优先，退回 FCC 回写，亮屏/息屏都保持，含基准学习与温度闸
- 电池 NTC 伪装（`batt_spoof`），不按真实温度撤销
- 遥测（`run/sensor`）与心跳（`run/hb`，`uptime pid` 格式）
- 高刷补写（`hz_hard`）、描述同步（`module.prop`）
- `SIGUSR1` 立即重载、`spoof.pending` 补齐、退出全量还原

C 版另有几个只读子命令，排障时不必进守护：

```sh
su 0 sh -c '/data/adb/modules/quickcharge/bin/qcmon zones'    # 温区分类表
su 0 sh -c '/data/adb/modules/quickcharge/bin/qcmon once'     # 单轮目标值（不落盘）
su 0 sh -c '/data/adb/modules/quickcharge/bin/qcmon sensor'   # 跑一轮热路径并打印遥测
su 0 sh -c '/data/adb/modules/quickcharge/bin/qcmon bench 200' # 热路径耗时
```

差异只在这些地方，都不影响充电行为：C 版没有 `action.sh` 的命令行子集——面板和
命令行仍然走 `action.sh`，两版共用。

## 默认策略

```
真实 30～38℃  →  上报 30℃     温差顶满 12℃
真实 39℃      →  上报 33℃
真实 40℃      →  上报 36℃
真实 41℃      →  上报 39℃
真实 ≥42℃     →  关闭模拟，系统读真实值自行降频
```

最后 4℃ 等步长爬升是必要的：从 30 直跳 42 会让系统看到壳温突变 12℃，反而触发一次额外降频。

## 参数

| 参数 | 默认 | 范围 | 作用 |
|---|---|---|---|
| `temp_mode` | `charge` | `off` / `static` / `charge` | `static` 全程伪装；`charge` 只在充电时伪装（默认），不看电量 |
| `shell_temp` | 25 | 20～33 | 伪装温度（℃），恒定上报这个值，与真实读数无关 |
| `core_temp` | `off` | `off` / 20～100 | CPU/GPU/DDR 固定伪装温度；`off` = 不伪装 |
| `noncore_temp` | `off` | `off` / 20～100 | 其它温区固定伪装；电池 NTC 需用 `batt_spoof` 单独开 |
| `batt_spoof` | `off` | `off` / 20～45 | **电池 NTC 伪装**：电池温区按此值上报；读不到真实温度也照开，不按温度撤销 |
| `curve_offset` | 120 | 0～300 | 充电曲线温度轴右移量，0.1℃ 单位（120 = +12℃） |
| `power_scale` | 100 | 50～200 | 电流校准百分比，读数偏低/偏高时微调 |
| `cells_mode` | auto | `auto` / 1 / 2 | 电芯数：自动判断，或强制单芯/双芯（个别机型第二槽位有残值时用） |
| `tick` | 15 | 5～300 | 守护周期（秒） |
| `log_level` | 1 | 0～4 | 0 只留 `E` / 1 事件（默认）/ 2 事件+快照 / 3 逐轮 / 4 调试 |

3.1.0 删掉的键：`wall`、`aggr`、`curr_max`、`curr_edge`、`fast_cap`、`battery_limit`、
`sentinel_limit`、`cool_guard`。升级时 `customize.sh` 会把它们从 `state.conf` 里清掉，
真机残留也无害——守护不再读。

`shell_temp` 的下限是硬性的：再低不少平台会把 NTC 判成开路，直接锁 5V/500mA，反而更慢。

任一参数越界都会被拒绝，当前值保持不变，不会写进系统。

## 命令

**日常配置用 WebUI。** 命令行是给脚本和排障用的，`sh action.sh` 不带参数只打印状态，不会进交互菜单 —— KernelSU / APatch 执行命令时没有终端，菜单里的 `read` 永远等不到输入，只会显示一堆「选择:」让人以为卡住了。想要菜单请显式敲 `sh action.sh menu`（仅限终端模拟器）。

```sh
sh action.sh status                 # 状态
sh action.sh temp static 25         # 开启伪装，恒定报 25℃
sh action.sh temp off               # 关闭伪装
sh action.sh base 22                # 只改伪装温度，不切模式（20～33）
sh action.sh hz 120                 # 写 120Hz（系统仍可按内容降频）
sh action.sh hz 165 hard            # 强制锁定 165Hz（不接受内容帧率切换）
sh action.sh hz 185                 # 185Hz 机型（2025 年新机）
sh action.sh hzguard off            # 关掉强制锁定，档位保留
sh action.sh hz off                 # 完全还原系统刷新率
sh action.sh pscale 110             # 电流读数偏低一成时校准
sh action.sh cells 1                # 强制按单电芯算功率（自动判断误判时）
sh action.sh check                  # 适配检查：一次采样，直接说能用哪些功能
sh action.sh core 55                # CPU/GPU/DDR 固定报 55℃（独立于 temp 模式）
sh action.sh batt 30                # 电池 NTC 按 30℃ 上报（不按真实温度撤销）
sh action.sh unlock on              # 解除 HAL 阶梯限流（写 0，原值备份）
sh action.sh level 2               # 详细日志（开启时先写环境头）
sh action.sh logs e 100             # 最近 100 条错误
sh action.sh logs boot              # 本次开机全过程
sh action.sh probe                  # 温度读取自检：温区/电池节点/缓存/决策现场
sh action.sh zones                 # 温区判定全表：type / 语义类 / 是否 core 候选 / 节点名

`zones` 里 `core 候选 0 个` 而 `probe` 每行都是 `ok` 时，看的是同一个温区表：
`probe` 只判断"读到了非空字符串"，`zones` 走的是语义分类。两者的交集才是可用节点。
sh action.sh rebuild                # 重新生成覆盖层（一般不用，OTA 后开机自处理）
sh action.sh reset                  # 恢复初始状态
```

`logs` 的来源标记：`boot` / `mount` / `override` / `thermal` / `guard` / `charge` / `daemon` / `cmd` / `env` / `proto` / `screen` / `chg`。

**日志级别（2.9.60 起）**：`0` 只留 `E` / `1` 事件（默认）/ `2` 事件+完整快照 / `3` 逐轮 / `4` 调试。默认落在 1：安装、守护启停、挂载交付都留痕，又不至于每轮刷屏。
面板仍是「关闭 / 详细」两态，点「详细」走级别 2，并且**开启时先写环境头**：
机型、ROM、内核、模块与守护版本、`usb/type`、`real_type`、`voocchg_ing`、`charge_technology`、
屏幕亮度节点数与 FCC 节点，最后补一条当前现场（`首帧`）。
复现完直接导 `log.txt` 就能定位，不用再问机型、节点、判定依据。

快照行（`[chg]`）字段：

```
vusb=9.00V iusb=2.03A imax=2.00A vbat=4.300V ibat=-4000mA
pin=18.3W pb=17.2W 50% 34℃ cool=0 vooc=0 tech=7
type=USB_DCP scr=1 proto=vooc cells=2 status=Charging
```

- `iusb` 是输入侧**实测**电流，`imax` 只是充电器上限，别用后者判断实际输入
- `pin` / `pb` 是输入功率与电池侧功率（单芯口径，双芯机型乘 2）：输入掉而电池不掉是充电器或线的问题，两边一起掉才是降档
- `type` / `rtype` / `vooc` / `tech` 是原始节点，照抄不加工。2.9.72 起日志不再写协议结论（面板 2.9.67 就取消了协议显示），要判断协议只能自己看这几个数：`tech` 落在 1 到 13 是私有档，`vooc=1` 表示私有握手已经开始，`type` 里出现 VOOC / DART / Flash 字样同样是私有，`tech` 14 及以上是退档后的公有 PD
- 别拿 `usb/voltage_max`、`current_max` 判断有没有插充电器：这两个是**端口能力上限**，拔线后常驻 5V/500mA。判断在位要看 `usb/online`、实测 `iusb`、电池 `status` 三者

**日志每次开机清空**：`post-fs-data` 一进来就把上一轮的 `log.txt` 与 `log.old.txt` 删掉，所以 `logs boot` 拿到的就是这一次开机的完整链路，不会和几天前的记录混在一起。`post-fs-data` 万一被跳过（安全模式、元模块没接线），`service.sh` 会用「日志的最后写入时间早于本次开机时刻」兜底再清一次；判断不出来时不动它，宁可留着也不误删本轮记录。

## WebUI

模块带 `webroot/index.html`，在 **KernelSU / KsuWebUI / MMRL** 里点模块的「打开」即可看到控制面板：

- 实时状态四格：**真实**（传感器实际温度，下方小字直接写用的温度点，如 `batt`）、**系统看到**（模块写进 `emul_temp` 的数，充电策略和温控服务读到的就是它）、**配置**（生效条数）、**守护**（是否在跑 + 心跳）。下面一行结论只留数字关系：`真实 41℃ → 系统看到 25℃`、`恒定 25℃ · 不看真实温度`、`待机中 · 插电后接管`、`写入失败 · 系统仍读真实温度`
- 读不到温度时只留横线，小字写原因：`守护没跑` 或 `通道被挡`（管理器的执行通道与终端 `su` 不是同一个 SELinux 域）。守护在跑时优先用它的读数，不依赖这条通道
- **实时功耗**卡：电流 / 功率 / 电池温度三格，附一条只在页面打开时采样的曲线；标题旁只标电芯数与平台（`双电芯 · 高通`），协议不上屏
- **温控改写范围**三个按钮：全局运行 / 仅充电 / 关闭，点一下立即生效
- **核心参数**：只留一个「伪装温度」滑块，20 到 33℃（拖动即生效），下面一行小字写「恒定上报这个值：不设温度墙、不设熔断线、不按电量退出」
- **极限功率**：电池 NTC 伪装、取消阶梯限流、CPU 伪装三个危险开关，默认不动，标题行写「安全边界未动」。CPU 伪装是 20 到 70℃ 滑块直接指定系统读到的核心温度，不给系统任何"变热了"的信号；勾上「关闭伪装」即交回真实温度。设得越低，调度越不会降频，真实发热不会跟着降。WebUI 的执行通道常常读不到 `/sys/class/thermal`，这种情况命令只落状态、由守护在自己的域里补挂。分类表认不出温区名字时，core 会按「排除法」兜底：电池、主板、壳温默认不碰，其余节点照常伪装，回执里标注「分类未命中，按节点兜底 N 个」
- **刷新率**：6 格滑块，关 / 90 / 120 / 144 / 165 / 185Hz，本机没有的档位变灰、拖不过去；外加「强制锁定」开关
- **诊断日志**：只有「关闭 / 详细」两个按钮，点详细才开日志并先写环境头；面板里不再显示日志正文，要看内容用 `action.sh logs`
- 底部操作区三个按钮一行：刷新 / 重挂 / 重启守护

面板上已经删除的东西，别再找：充电限流滑块、暴力模式开关、温控档位与温度墙滑块、熔断阈值两个滑块（均在 3.1.0 随功能一起删除）、环境自检卡（2.9.65 去掉，改用 `action.sh check` 与日志）、协议标签（2.9.67 去掉，判定与日志在 2.9.72 一并移除）、顶部状态牌（2.9.69 加过一版，2.9.70 撤销，状态改由 `module.prop` 简介承担）。

滑块松手才下发命令，避免拖动过程刷屏；参数走的是 `action.sh`，与命令行完全一致，改完立即生效，不需要重启。

六张参数卡默认收起：一屏能看完状态、功耗、改写范围，需要调参再点开。收起时标题行右侧显示当前值，
所以「看一眼墙设成了多少、现在锁在多少帧」不用展开。展开/收起是 300ms 的高度过渡，箭头同时旋转；
展开状态记在 `localStorage`，存不住（部分管理器的 iframe 禁用）就只在本次会话生效，不影响功能。

滑块对触摸做了防误触处理：**点按轨道不会跳值**，只有左右拖动超过 8px 才进入调整，纵向滑动时手指扫过滑块不会改动参数；拖动中和松手后的 2 秒内，后台每 30 秒一次的刷新不会回写滑块，避免"手指还在拖、值被刷回旧位置"。

### 真实温度为空 / 守护显示停止 / 限流没反应

**「真实」一栏长期是 —，或者守护一直显示「停止」。** 这两件事是同一个原因：页面通过管理器的 `exec` 执行命令，那个环境的 SELinux 域和终端里的 `su` 不一定相同；读 sysfs 被拒时，整片读数就是空的。守护进程本身也常常起不来——`nohup ... &` 只挡 SIGHUP，挡不住 Magisk / KernelSU 在脚本退出时清理子进程组，进程起来一两秒就被收掉，只留下一个 pid 文件，于是永远显示「未运行」。

现在分五层解决：

1. 守护用 `setsid` 起在独立会话里，脚本退出不会被一起收掉；启动后还会回读 pid 确认，失败会写进日志。
2. 守护每 tick 把读数写进 `run/sensor`、并写一次心跳 `run/hb`。状态查询优先用缓存，页面拿到的就是守护亲眼读到的值，绕开了 WebUI 的权限差异。
3. 缓存过期（守护停了）才现场读；哨兵读不到时还会扫一遍全部温区兜底，宁可显示别的传感器，也不留一个横线。
4. 温区整个读不到（ColorOS 上 SELinux 挡住执行域很常见），最后退到 `power_supply/battery/temp`。这条路径通常仍可读，至少保证熔断和伪装不是瞎的。
5. 异常关机（长按电源、看门狗重启、被低内存回收）时守护来不及收尾，`run/daemon.lock` 与 `run/daemon.pid` 会留在 `/data` 上。重启后那个号码常被系统进程复用，旧逻辑只看「这个 pid 还活着」就认定守护在跑——于是面板一直「停止」，点启动又回「已有守护在运行」，整轮开机都拉不起来。现在判定守护必须核对 `/proc/<pid>/cmdline` 里有没有 `service.sh`（读不到才退到心跳，且要求心跳里的 pid 对得上），开机时、拉起前、停止后都会清掉「号在人不在」的残留锁。

面板上「真实」下面那行小字会写明来源：`守护缓存` 还是 `现场读取`；读不到时直接写「读不到」和原因，而不是一个看不出所以然的破折号。

**还有一种"假成功"**：目标温度算出来了，但 `emul_temp` 一个都没写进去（节点不存在、或被 SELinux 拒写）。这时面板会把「系统看到」标成**写入失败**，而不是「已改写」。写入回执由守护每 tick 记进 `run/sensor` 的最后一列。

排查分两个命令：

- `sh action.sh check` —— 一次采样给结论，不依赖守护、不等 tick。逐项列出温区、温度改写、配置改写、限流、电芯，最后给 A/B/C/D 的可用等级。**换了新机型先跑这个。**
- `sh action.sh probe` —— 详细现场。温区列表、每个节点的原始 `temp`、电池节点、`bcc_parms` / `aging_ffc_data` 原始行、缓存与当前决策。哪一段是空的，问题就在哪一段。

**限流调了没反应。** 两个问题叠在一起：`sd_set_curr` 调用了一个并不存在的 `sd_curr_apply`，命令直接 `not found`，面板却照样提示"已更新"，节点一次没写。现在补上了，改完立刻落到节点，不用等下一个 tick。

另外节点单位不统一（power_supply 下是 µA，部分 oplus_chg 节点是 mA），改成按节点当前值判断，避免写错一个数量级。守护每 tick 复查：目标变了就压或抬，目标没变只在系统把上限抬回去时压回。**只压不抬会出另一个毛病**——温度降下来、目标回到满值，节点却永远停在最低那一档，用户看到的是"温度降了，功率没恢复"。

**关掉限流之后还在限。** `curr_max` 改成 0 以前只写 state，限流节点一个字节没动：面板显示"不限"、实际还在 3A。现在第一次改写前会把节点原值记到 `run/curr.orig`，关闭限流、卸载模块时按记录还原。这份记录**跨守护重启保留**：早先 service.sh 每次启动都删它，重开守护时节点已经是限流后的值，新基线就会把 3A 当成原值，卸载后还原不回去。换充电器导致原值不同也没关系，重启后系统会自己把节点复位。

**出问题只看日志。** 面板不再单独做自检页：数值出不来、按钮没反应时，展开「诊断日志」点「详细」，先看环境头（设备 / ROM / 内核 / 模块版本 / 执行通道），再按 `E`、`W` 找第一条异常。红条只说明断在哪一段，细节一律回日志里查。

注意这个参数**不是加速用的**：功率由适配器、协议、电芯内阻决定，调高不会更快，调低才会真的变慢。它的定位是限流保护。

### 温控改写范围

三个按钮对应 `temp_mode` 的三个取值，差别是**生效时机**，不是强度：

| 按钮 | 值 | 行为 |
|---|---|---|
| 全局运行 | `static` | 任何场景都改写：插电、拔电、游戏、待机都生效 |
| 仅充电 | `charge` | 插电时改写；拔电后 10 秒内还原，回到系统原温控 |
| 关闭 | `off` | 不写任何温控节点（覆盖层仍在，见下节） |

切到「仅充电」时会先看一次电源状态：没插电就立刻撤掉已写入的伪装，不等下一个 tick。
之后守护每 **10 秒**查一次电源状态，与 `tick` 无关——`tick` 调到 300 秒也是 10 秒，
拔电后最多 10 秒还原。这 10 秒一轮的成本可以忽略，因为 `sd_charge_tick` 不 fork。

### 「还原」还到哪一层

这里分两层，说清楚免得误解：

| 层 | 拔电后 |
|---|---|
| 传感器读数（`emul_temp` / `/proc/shell-temp`） | 归零，系统重新读到真实温度 |
| `/vendor/etc` 温控配置覆盖层 | 仍挂着，运行时不解挂 |

第二层是模块实现「满功率」的核心：把 `sys_thermal_control_config*.xml` 里的
`enable="true"` 改成 `false`，系统才不会在 42℃ 就降频限流。这些文件在 thermal HAL
启动时读一次，运行时解挂不会让已加载的策略失效，所以「拔电即还原」只能是传感器层。

要彻底回到原厂，卸载模块后重启。


## 模块简介显示当前状态

管理器（Magisk / KernelSU）模块列表里那一行简介是 `module.prop` 的 `description`。出厂文案只有一句：

```
QC·欧加真温控与充电改写
```

运行起来之后，这一行会改成「状态 + 摘要」，并且**状态排在第一位**——管理器列表会截断长文案，排在后面等于没有：

| 场景 | 简介 |
|---|---|
| 守护正常 | `✅ 运行中 · 温控档位 8/10 · 高刷 120Hz · 配置 9 项` |
| 刚装完 / 刚更新，还没重启 | `❌ 请重启 · 重启后开始工作` |
| 守护没起来 / 卡死 | `❌ 未运行 · 把 /data/adb/quickcharge/ 的日志发给作者` |

为什么用 ✅ / ❌ 而不是给文字上色：管理器把 `description` 当纯文本交给 `Text()`，不解析 HTML，写 `<font color="...">` 只会原样显示成标签。这两个 emoji 自带颜色，Magisk / KernelSU / APatch 下表现一致。

判定顺序是「先看进程，再看是不是刚装完」：

1. 守护 pid 存在、且心跳不超过 180 秒 → 运行中。pid 在但心跳超时也归到「未运行」——进程活着不代表循环没卡死。
2. 没有守护时，依次看三个「刚安装」信号，命中任一即「请重启」：更新包还在 `modules_update`、安装脚本写的 `need_reboot` 标记还在、本次开机没有写过 `.boot_id`。
3. 三者都不命中，说明开机流程已经跑完、守护本该起来却没起来，这才是真故障，把位置留给日志路径。

`.boot_id` 记的是**开机时刻**，不是文件 mtime：部分机器在 `post-fs-data` 阶段时钟还没校正好，mtime 会落在「开机之前」，据此判断会一直误判成刚装完。开机时刻由 uptime 反推，同一轮开机内误差不超过 1 秒，比较时留 15 秒余量。

摘要只在运行中才拼——没跑起来却被写「档位 8/10」是误导：

| 状态 | 摘要 |
|---|---|
| 全程伪装 | `温控档位 8/10 · 高刷 120Hz · 配置 9 项` |
| 开强制锁定 | `温控档位 8/10 · 高刷 120Hz 锁定 · 配置 9 项` |
| 仅充电、高刷未开 | `温控档位 8/10（仅充电） · 配置 9 项` |
| 关闭、高刷未开 | `温度伪装关闭 · 配置 9 项` |

高刷没开时不再写「· 高刷关闭」——摘要只在有内容时才占位。

改写时机：安装完成、开机挂载完成、守护启动、切换模式、改参数、熔断。`post-fs-data` 阶段**不写**：那时守护还没起，写进去必然是「未运行」，几秒后又改回来，白白闪一下；改由 `service.sh` 首次写入。`action.sh json` 也会顺手校正一次，所以守护被外部杀掉后，打开面板就能把「未运行」写回去。

每次都会先读 `module.prop` 里实际的 `description` 再决定要不要写——只比内部缓存不够，覆盖安装会把整行换回出厂文案，缓存却还在，结果就是升级之后简介永远停在宣传语。只替换 `description` 一行，`id` / `version` 等逐字节保留。

读取前还会查一遍 NUL 字节：`module.prop` 被存成 UTF-16 时 `grep` 会把它当二进制，只输出一句 `Binary file ... matches`，面板就显示成 `vBinary file ... matches`。`sd_prop_get` 会按 UTF-16 / UTF-16LE / UTF-16BE 依次试 `iconv` 转回 UTF-8，原件留一份 `.utf16.bak`；所有读点都带 `grep -a`，修不好也不会把那句话当版本号。

两个已知限制：

- 管理器已经停在模块列表页时不会实时刷新，下拉或退出重进才会重新读取。
- 少数管理器会缓存 `module.prop` 一段时间，最长约 3 分钟（守护的同步周期）。

面板通过 KernelSU 的 `ksu.exec` 执行命令，纯静态页面、无外部依赖。Magisk 用户可装 KsuWebUI 独立应用加载。状态接口是 `sh action.sh json`，输出单行 JSON，也方便元模块或脚本消费。

### 页面打不开、点了没反应

2.7.1 之前的面板把回调函数当参数直接传给 `ksu.exec`。KernelSU 的原生签名是 `exec(命令, JSON字符串, 回调函数名)`，第三个参数要的是**名字**，原生侧再执行 `window[名字](...)` 回传结果——塞函数对象进去，`window[函数源码]` 是 `undefined`，回调永远不来，页面就停在“数值全是 —、按钮点了没动静”。

现在启动时会用 `echo` 依次试三种通道（回调名 / 函数回调 / 直接返回），选定一种后全程复用，命令带超时，失败不再静默：

- 顶部出现红条 → 红条写明断在哪一段，展开「诊断日志」看原始返回
- 红条写着“没有网页控制接口” → 不在 KernelSU / APatch / MMRL 的 WebUI 里。Magisk 用户用终端：`su -c sh /data/adb/modules/quickcharge/action.sh`
- 红条写着“命令通道没能建立” → 把诊断日志截图反馈

顺带把执行环境的 `PATH` 补齐了（`/data/adb/ksu/bin`、`/data/adb/ap/bin`、`/data/adb/magisk`、`/system/bin`）。有的管理器注入 WebUI 时环境变量很干净，`grep` / `awk` 都找不到，脚本会“跑得通但什么都不输出”，表现是一整页空值。

**刷新率。** 面板上是一条 6 格滑块：最左格「关」，之后是 90 / 120 / 144 / 165 / 185Hz，
再加一个「强制锁定」开关（两种力度）。

**本机没有的档位会变灰，而且拖不过去。** 模式表来自 `cmd display get-supported-modes`，
结果缓存在 `run/hz.list`（tmpfs，重启即清，`cmd` 单次冷启动上百毫秒，不能每次拉 json 都跑）。
拖动时落点一旦落在灰格，滑块立刻弹回上一格，标签和刻度都不会闪。

拿不到模式表时（老 ROM 没有 `cmd`，或 `dumpsys` 也读不出）**不灰任何格**——宁可让用户
试一次被后端拒绝，也别把整条滑块灰成拖不动。后端 `hz` 写入前还会再查一次，
不支持就列出本机档位并返回失败，滑块弹回原档。

最左格「关」就是 `hz off`：`peak_refresh_rate` / `min_refresh_rate` 还原成第一次锁定前的值，
原本没有这两个键就直接删掉，不写 60 —— 交回系统比写死 60 干净，系统自己还会按省电、
视频帧率继续降。命令层仍是 60～185 的连续范围，老配置（60/75）不会被判非法。

*普通档* 写系统 `peak_refresh_rate` 与 `min_refresh_rate`，和 ColorOS「屏幕刷新率」开关走同一路径，改完立即生效。开启前记下原值，关闭时原样写回；原本为空的键直接删除，交还系统默认。

*强制锁定* 在这个基础上多做两件事：把 `secure/match_content_frame_rate` 置 1（不接受内容帧率匹配），并让守护每 15 秒回读两个键，被系统改回就立即补写。视频播放时的 24/30fps 降频、静态画面下的降档，都能挡住。

### 为什么"锁定"不是绝对的

Android 的刷新率由 `DisplayModeDirector` 用固定优先级的**投票**决定，不是"谁后写谁赢"。高优先级会把低优先级的区间直接裁掉：

| 投票源 | 优先级 | 效果 |
|---|---|---|
| `min_refresh_rate` | 3 | 用户下限 |
| App `Window.setFrameRate` | 4 | 应用自报帧率 |
| `preferredDisplayModeId` | 5 | 应用指定模式 |
| `peak_refresh_rate` | 7 | 用户上限 |
| 省电模式 | 8 | 强制 `[0, 60]` |
| 皮肤温度 CRITICAL | 10 | 强制 `[0, 60]` |
| 屏下指纹解锁 | 12 | 成像期间锁帧 |

所以 `peak` / `min` 只能"表达偏好"。模块能做的只有两件事：把键写进去，并在被改回时补写。**下面三种场景挡不住**，面板会如实显示原因，而不是假装已锁定：

- **省电模式**（优先级 8）：`low_power=1` 时系统直接裁到 60Hz，写键无效。守护检测到后主动退让，面板显示「省电模式开启，锁定无效」。
- **皮肤温度过高**（优先级 10）：这是面板保护。硬顶等于拿屏幕寿命换帧率，模块不绕。
- **屏下指纹解锁瞬间**（优先级 12）：光学指纹要求固定帧率才能成像，持续几百毫秒，解锁完自动恢复。

还有一层：App 自己在 Surface 上设的帧率（优先级 4）是**逐层**的，SurfaceFlinger 会按活跃层选倍频。这一层要在 SurfaceFlinger 里改，超出 settings 的能力范围；能改的模块通常靠 hook，代价是黑屏与兼容性风险，本模块不做。

**连续三次写不回目标值就停手。** 继续每 15 秒和系统抢一次写，只会白耗 IO 并刷日志。此时守护记一条「已暂停补写（厂商锁定显示策略）」，面板显示 `drift`。

**代价。** 强制锁定会让 LTPO 面板失去降频省电的机会，功耗与发热都会上升；长时间高刷对 OLED 寿命也有影响。所以它默认关闭，开启时面板会二次确认。关闭后档位保留，只是把内容帧率策略交还系统。

**功耗。** `sh action.sh power` 读一次电池节点，返回 `ma` / `mv` / `w` / `temp` / `status` / `cells` / `cells_src` / `src`。两条路径按顺序尝试：

1. **`/sys/class/oplus_chg/battery/bcc_parms`** —— 欧加真专属，逗号分隔 19 个字段，`[6]` 是电芯 0 电压、`[8]` 是电流、`[11]` 是电芯 1 电压，单位 mV / mA。
2. **`/sys/class/power_supply/battery/*`** —— 通用节点，电流自动识别 µA 与 mA，电压识别 µV 与 mV。

**双电芯为什么必须走第一条路。** 串联双电芯的总压是两颗相加（4.4 + 4.4 = 8.8V），但部分机型的 `voltage_now` 只报单芯电压。按 4.4V 算出来的功率正好少一半，30W 快充会显示成 15W。`bcc_parms` 里两路电压都在，相加才是真实总压。

**电芯数按五层判定，不靠单一阈值。**

| 优先级 | 依据 | 说明 |
|---|---|---|
| 1 | `cells 1` / `cells 2` | 用户手动指定，永远最高 |
| 2 | `/sys/class/oplus_chg/battery/aging_ffc_data` | 驱动自己数出来的，第二位就是串联节数（`0,2,...` = 双芯）。新系统都有，最可靠 |
| 3 | `bcc_parms` 两路电压推算 | 只给没有直报值的老机型兜底，三项同时成立才算双芯 |
| 4 | `battery/voltage_now` > 6V | 既没直报值也没 `bcc_parms` 时，整包电压反推。单芯永远上不到 6V，方向是保守的 |
| 5 | 默认单芯 | 都判不出时选它：宁可少算一半，也不能把单芯认成双芯把功率吹高一倍 |

第 3 层的三项是：两颗都落在 2500～5000mV 的电芯区间、彼此相差不超过 500mV、总和落在 7000～9600mV。早先的判据只有"大于 1V 就算第二颗"，单电芯机型第二槽位留残值时会把总压算成 5.9V、功率虚高。GT Neo3 这类 MTK 机型就是在这个位置踩到的。

直报双芯但 `bcc_parms` 第二槽位是 0 时，按单芯电压翻倍；第二槽位是明显不合理的值时同理，不会把噪声加进去。`power` 输出的 `cells_src` 会写明这次用的是哪一层（`manual` / `aging` / `bcc` / `volt` / `default`）。

**整包电压取值顺序**与加加电池一致：`battery/voltage_now` 看起来是单节（2.5～6V）而判定为双芯时，先试 `bms/voltage_now`——电量计直接给的整包读数，读得到就用它；读不到才按串联数 ×2。已经 ≥6V 的一律当整包，不重复乘。单芯机型的这段代码会直接返回原值，读数一个字节都不动。

字段数不是 19 说明驱动版本不同、索引会错位，此时直接放弃这条路，不猜位置。`sh action.sh probe` 会把 `bcc_parms` 原始行、解析出的 v0/v1 和最终判定一起打出来。

电流符号各平台约定相反，统一按 `status` 校正成「充电为正、放电为负」。读数仍有固定偏差的机型用 `pscale` 微调（百分比，50～200）。

面板每 3 秒采样一次，页面隐藏或关闭立即停止并清空，不写日志、不留后台进程。

> 双电芯读数的思路参考了 [PlusPlusBattery](https://github.com/dijia1124/PlusPlusBattery)（MIT），它把 `bcc_parms` 的字段位置和双芯相加的做法验证得很清楚。

## 平台适配：高通 / MTK / 欧加真

框架是通用的，生效路径不是。同一份代码在欧加真（OPPO / OnePlus / realme）的高通机和
MTK 机上，差别集中在四件事：温区叫什么、温度用什么单位、哪个节点真的能限流、内核有
没有另外一套温控。这四条不处理，模块能跑、日志好看，但充电功率一点不变。

### 平台判定：厂商字段优先，型号其次，cpuinfo 兜底

判断不看机型名（`ro.product.model` 是 `PJZ110`、`RMX3562` 这种渠道编码，跟 SoC 无关），
只看四个来源，按可靠性排序：

| 顺序 | 读取 | 命中示例 | 说明 |
|---|---|---|---|
| 1 | `ro.soc.manufacturer` | `MediaTek` / `Qualcomm` | Android 12+ 的标准字段，最可靠，不会被型号串里的子串带偏 |
| 2 | `ro.board.platform` + `ro.hardware` | `mt6895` / `mt6983` / `sm8750` / `taro` / `kona` | 老 ROM 常常没有厂商字段 |
| 3 | `/proc/cpuinfo` 的 `Hardware:` 行 | `MT6895` | 前两级全空时才读，只在这条兜底路径上 fork |
| 4 | 兜底 `other` | — | 不猜，按通用路径处理 |

匹配只认这些形态：

- **MTK**：`mt` / `MT` + 4 位数字（`mt6895`、`MT6983`）、`MTK`、`MediaTek`
- **高通**：`sm` / `SM` + 4 位数字（`sm8750`）、`msm` + 数字（`msm8998`）、`qcom`，
  以及骁龙 8 系的平台代号 `kona` / `taro` / `kalama` / `crow` / `pineapple`

最后一行是关键：高通的 `ro.board.platform` 报的是代号而不是型号，ColorOS 上
`taro` = SM8450、`kalama` = SM8550、`pineapple` = SM8650。只按 `sm8xxx` 匹配会漏掉
一大半骁龙机，然后被当成 `other` 走通用路径 —— 看着能跑，MTK 那套提前降档却也没生效。
所以代号必须列进来。

判定结果带依据一起输出，`other` 时显示原始值，方便直接贴出来排查：

```
[ok] 平台     MediaTek（MTK） · mt6895 · 降档提前 2℃
[ok] 平台     Qualcomm（高通） · taro
```

### 温区命名：按语义分类，不能按名字匹配

| 平台 | 电池 | CPU / SoC | 主板 |
|---|---|---|---|
| 高通 | `battery` | `cpu-0-0` / `gpu` / `ddr` | `xo-therm` / `xtherm` |
| MTK 公版 | `mtktsbattery` | `mtktscpu` / `mtktsAP` / `tzts1..4` | `mtktspmic` / `mtktswmt` / `mtktspa` |
| MTK 欧加真（GT Neo3 实测） | `mtk-battery` | `cpu_big1..5` | `mtk-mst-div-charger` / `mtk-slv-div-charger` |

第三行是真机上抓到的：欧加真把 MTK 的温区重命名成带连字符的形式，公版文档里查不到。
名字不同但都落在同一类里——`mtk-battery` 命中 `*battery*`，`cpu_big1` 命中 `cpu*`，
`*-div-charger` 命中 `*charger*`。这也是不用名字白名单的原因。

只写 `battery`、`cpu*` 这种精确匹配，在 MTK 上会同时坏两件事：哨兵选不到电池，退到
`mtktscpu`（SoC 结温），熔断阈值从 48℃ 变成 85℃——电池那一路等于没有保护；`noncore`
伪装还会把 `mtktsbattery` 一起钉死，充电 IC 失去 NTC 反馈。

现在统一归一成五类：`core` / `shell` / `battery` / `board` / `other`。哨兵按
`battery > board > other` 选，`battery` 与 `board` 永不参与伪装——3.1.0 删掉熔断之后，
这条排除规则仍然有效，它决定的是"哪些温区绝不能被 core/noncore 伪装误伤"。

下面两段是熔断还在时（2.8.0 到 3.0.x）踩过的坑，保留下来是因为分类逻辑没变：
熔断扫描也得走同一套分类。2.8.0 之前这里还留着一份写死的名字表
（`battery|Battery|batt*|xo-therm|xtherm`），哨兵选了 `mtktsbattery`，熔断却按名字找
不到它，于是退到"第一个非 core/shell 温区"——GT Neo3 上那个是 `mtktspmic`，拿 85℃ 的
阈值去盯 PMIC，电池 50℃ 也不会熔断。恢复条件的问题相反：它把 PA、WiFi 也算进"是否
降温"，而这两颗芯片正常工作时就 90℃ 以上，一旦熔断就永远解不开。

当时的熔断与恢复都只认 `sd_zone_is_guard_src`：电池类 + `xo-therm` / `xtherm*` / `*pmic*` /
`*charger*`。PA（`mtktsbtsmdpa`）、WiFi（`mtktswmt`）明确排除——它们不是"机身有多热"
的度量，拿来熔断只会天天误触发。3.1.0 把这个函数连同整套熔断一起删了。

### 读数不可信时：-40000 / 2000 / 0

真机上三种"看起来像温度、其实不是"的值都会出现，处理方式各不相同：

| 值 | 出现位置 | 含义 | 处理 |
|---|---|---|---|
| `-40000` | `mtk-mst-div-charger` / `mtk-slv-div-charger` | 这路从来没被采样过 | 负数一律判读不到，不进哨兵、不进熔断 |
| `2000` | `mtk-battery`（GT Neo3） | 未初始化，或单位不明（2℃ / 20.00℃ 都可能） | 8-90℃ 之外判为不可用，改用电量计 |
| `0` | `shell_front` / `shell_frame` / `shell_back` | 壳温还没上报 | 只当伪装目标，绝不当哨兵 |

`2000` 这条最坑：按 mC 归一得到 2℃，目标温度被压到 2℃、低于写入下限被拒，
表现就是「模式开着、全程未改写」。当时伪装目标、限流目标、熔断、熔断恢复四个
决策点统一走 `sd_sentinel_best_v`（3.1.0 起只剩遥测显示这一条）：电池类温区读数落在 8-90℃ 之外时改用
`battery` / `mtk-battery` / `mtk-gauge` 的电量计读数。`probe` 会把这种情况直接标出来：

```
!! 温区 thermal_zone4 报 2℃（不在 8-90℃）→ 判定未初始化，改用电量计 35℃
```

刻意不做"谁高听谁"：那会让一路偏冷的陈旧读数盖过真实的过热读数。

### 温度编码：三种并存

| 原始值 | 编码 | 来源 |
|---|---|---|
| `26000` | 毫摄氏度 | MTK thermal zone、多数高通温区 |
| `450` | 0.1℃ | `power_supply/battery/temp` |
| `45` | 摄氏度 | 少数老内核 |

分界取 `2000` / `150`：0.1℃ 编码在手机工作区间是 250～600，mC 是 15000～60000，中间
的空档不会误判。归一后仍超过 150℃ 的值直接判为读不到——宁可熔断不工作，也不能让
`450` 这种值把伪装永久关掉。

### 电流节点：MTK 有三条，别写错那一条

| 平台 | 节点 | 单位 |
|---|---|---|
| 通用 | `battery/constant_charge_current_max`、`battery/current_max`、`usb/current_max` | µA |
| MTK | `battery/input_current_limit`、`charger/current_max` | µA |
| MTK 分体充电 | `mtk-master-charger/current_max`、`mtk-slave-charger/current_max`、`mtk-battery/current_max` | µA |
| 欧加真 | `oplus_chg/battery/chg_current_max` | mA |

GT Neo3 的 80W 是主从两路充电 IC，只压 `battery/input_current_limit` 时另一路仍在
满功率跑，总电流掉不下来——所以主从各自的 `current_max` 都要写，且都只往低压。

节点表分两层：通用层所有平台都写，MTK 层只在天玑上追加。分开的原因是
`input_current_limit` 这个文件名两个平台都有、语义却不同 —— MTK 上是"电池充电电流
上限"，高通上是"适配器输入电流上限"，在高通上写它等于额外压低输入功率。所以
`_sd_plat=qcom` 时的写入名单与 2.7.x **逐项一致**，一个节点都不多。

单位不靠路径猜，按节点当前值判断（`>100000` 视为 µA），写错一个数量级比不写更危险。

> **`/proc/mtk_battery_cmd/current_cmd` 不是电流节点。** 它的写入格式是 `"0 0"` /
> `"0 1"`（是否限流、是否充电），往里写 mA 会被驱动当成非法命令，实测有直接死机
> 重启的案例。本模块只探测它的存在，绝不写入。

### 内核还有一套温控

MTK 的充电温度保护在 `charger-manager` 里独立判定，用户空间还在 100% 的时候它可能
已经硬砍一档。3.0 起本模块不再额外给 MTK 提前 2℃：四档阈值与高通一致，真实温度到
墙前 3℃ 才降第一档，避免"离墙很远功率就掉了"。

### 投票路径（UFCS / PPS）：知道就行，不要写

`/proc/oplus-votable/` 下的 `UFCS_CURR` / `PPS_CURR` 是欧加真的充电投票接口，提高票值
在公有协议下可能转化为实际电流。但它有两个硬限制：

1. **VOOC / SuperVOOC / SuperDart 私有协议不生效。** 功率由充电器与充电 IC 握手决定，
   投票值再高也没用，而原装快充头几乎都是私有协议。
2. 票值不等于电流，只是参与决策的权重，最终还要过温控与电池策略。

写入投票节点属于"可能改变充电状态"的操作，出问题很难从日志倒推。本模块只探测
`/proc/oplus-votable` 是否存在并在 `check` 里报出来，不做任何写入。

### 怎么确认这台机器走通了

```sh
sh action.sh check
```

输出里这三行是新增的：

```
[ok] 平台     MediaTek（MTK） · mt6895 · 降档提前 2℃
[ok] 协议     VOOC / SuperVOOC 私有快充（协商 10V/7300mA）
[--] 投票     /proc/oplus-votable 不存在 · 私有协议下本来也不适用
```

- 平台判 `other`：`getprop` 与 `/proc/cpuinfo` 都没给出可识别字段，按通用路径处理，
  不影响伪装与熔断。
- 协议判「未识别」：通常是没有插充电器，`usb/voltage_max` 还没协商出值，插上再跑一次。
- 限流一栏为空：`check` 会直接提示该找哪个节点。

`sh action.sh probe` 会列出每个温区的语义类，贴出来就能判断是不是选错了哨兵。

## 安全设计

> **3.1.0 起这套"安全"只剩边界校验和退出还原。**熔断、温度墙、渐进让步、到墙滞回
> 全部删除，模块只追求充电速度。下面几条是仍然生效的部分；被删掉的那些写在本节末尾，
> 留作记录。

**哨兵隔离。** `battery` / `batt*` / `mtktsbattery` / `xo-therm` / `xtherm*` 这类电池与主板
传感器默认不参与伪装。判断按语义分类而不是按名字，MTK 的 `mtktsbattery`、`mtktspmic`
一样会被挡住。把它们一起钉死会让充电 IC 失去温度反馈——这是"充着电死机"的主要来源。

唯一例外是 `batt_spoof`（默认关，需显式开启，详见「极限功率」）。它只改电池**温区**，
不改 `power_supply/battery/temp`：后者是充电 IC 的 ADC 真实读数，面板上「真实」那一格
读的就是它。

**范围校验。** 伪装温度必须落在 20～33℃，越界不截断到边界而是拒绝：命令行入口直接报错、
当前值不变（`temp` 命令例外，越界退到 25℃）。`state.conf` 里的损坏值在读取时回落默认，
不会带着坏值去写节点。下限 20℃ 是硬性的——再低不少平台把 NTC 判成开路，直接锁 5V/500mA。

**写入门槛。** 非 0 的目标温度必须落在 20～100℃，否则整次写入丢弃并记 `E` 日志。
0 是合法值，语义为关闭模拟、交还真实读数，不是"上报 0℃"。

**降流解除带电流闸。** `cool_down` 非 0 且实测 `|ibat| < 2.5A` 才写 0。已经满速时
不碰这个节点：写入本身会让 OPlus 重选档，实测 4.3A 时写一下就从 32W 掉到 6W，
PKB110 上还会一路抖到 6W。

**退出还原。** 三条退出路径（正常退出、`uninstall.sh`、`restart`）都会：`emul_temp` 归零、
`umount` 覆盖层、删除临时文件、把阶梯解锁的原值写回。

### 3.0.x 及更早版本有、3.1.0 删掉的部分

- **熔断**：电池 48℃ / 其他传感器 85℃ 触发时撤销全部伪装并暂停，回落到阈值下 3℃ 自动恢复。
  删掉的原因见 [README 第 9 节](../README.md#9-极速模式没有兜底)。
- **渐进让步与 2℃ 滞回**：上报值随真实温度抬高、距墙 4℃ 开始爬升、到墙交还；到墙后
  回落 2℃ 才重新接管。现在上报值是恒定的，不存在"墙"这个概念。
- **温差档位（`aggr`）**：按档位拉开上报值与真实值的差距，0 到 10 档。
- **绝对电流墙（`curr_max`）与四档降流**：按温度把电流压到 100/75/50/25%。

## 配置改写范围

只扫这 7 个目录（`-maxdepth 2`）：`/vendor/etc`、`/odm/etc`、`/my_stock/etc`、
`/my_product/etc`、`/system/vendor/etc`、`/system/system_ext/etc`、`/vendor/qti/etc`。
（完整清单见下文「配置改写：目录、开关与自检」）。只改这些文件：

| 文件 | 改动 |
|---|---|
| `sys_high_temp_protect_*.xml` | `true` → `false`，阈值不动 |
| `sys_thermal_control_config*.xml` | 开关属性 `true` → `false`，档位数据保留 |
| `thermallevel_to_fps.xml` | `fps` 全部改 144 |
| `sys_thermal_config.xml` | 含 `enable` 的行 `>1<` → `>0<` |
| `devices_config.json` | 充电温度窗口 `150,450]` → `150,550]` |
| `QEGA_Config.txt` | `batt_spoof` 开启时取样节点 `xo-therm` → `battery`；关闭时保持原样 |
| `charging_*.txt` | 温度轴整体 +12℃（可调 `curve_offset`），上限截断 60℃ |

**只改属性值，绝不删 XML 节点。** 删节点会留下无主闭标签，产出结构残缺的 XML，thermal HAL 解析失败 → 开机循环。

每个产物落地前校验：开闭标签必须配平、标签总数必须与原件一致、JSON 括号数一致。原件本身不配平则直接拒绝改写。不一致的产物丢弃，宁可不生效也不写坏文件。

OTA 后系统指纹（`ro.build.display.id` + 安全补丁）变化，`post-fs-data` 会自动解挂、重新生成、重新挂载，不需要手动干预。

## 元模块：NoMount / Hybrid Mount / Magic Mount / Mountify

元模块负责把模块的 `system/` 目录送到真实文件系统里。它们分两类，本模块的应对也不同。

### 一、VFS 注入类（NoMount）

NoMount 类元模块（NoMount-Suite、`maxsteeel/nomount`）用 VFS 路径重定向注入模块文件，自身一条挂载都不产生。本模块原来用 `bind mount` 把改写后的配置贴到 `/vendor/etc`，在这种环境里就是一批计划外挂载，`nomount check` / Duck Detector 会直接报「挂载异常」。

检测到 NoMount 在位时（`/data/adb/modules/meta-nomount` 或 `/data/adb/modules/nomount` 存在且没被 `disable`），自动切换：

1. 覆盖层镜像到 `<模块目录>/system/vendor/etc/…`，交给 NoMount 的 metamount 注入；
2. 内容更新用**原地覆盖写**，inode 不变 —— 内核里的重定向规则继续指向同一个文件，改参数立即生效，不必 reload；
3. 只有文件增删（OTA 后配置列表变化）才调一次 `nomount reload`。

面板「挂载」格显示 `注入 N` 而不是 `0`，日志里有 `生效方式` 一行，能分清「真的没挂」和「用注入代替了挂载」。镜像写不进模块目录（只读安装）时才退回 `bind mount`，并在日志里记一条 `W`。

`sd_nm_mirror` 返回 2 有两种情形，调用方按产物数区分：`$SD_OVERRIDES` 里一个文件都没有（源配置缺失，无事可做）时静默跳过，不记 `W`、安装界面也不报错；有产物却镜像不进去才算真失败。同理，`sd_mount_overrides` 先 `find` 数一遍产物再决定要不要报。

### 二、挂载类（Hybrid Mount / Magic Mount / Mountify）

这三家都在 `metamount`（KernelSU）或 `post-mount`（APatch）阶段挂载，**晚于所有模块的 `post-fs-data.sh`**。本模块如果在 `post-fs-data` 里自己 bind，随后就会被它们的 OverlayFS / Magic Mount 整体重挂覆盖掉，表现为「配置改写不生效」，而 `status` 里那几条挂载也确实从 `/proc/mounts` 消失了。

所以检测到任一家在位（目录存在，且没有 `disable` / `remove`）时，只做交付、不做挂载：把文件写进 `<模块目录>/system/vendor/etc/…`，一条 bind 都不做，由它自己按规则挂上去。

| 元模块 | 识别目录 |
|---|---|
| Hybrid Mount | `meta-hybrid_mount`、`hybrid_mount` |
| Magic Mount | `meta-magic_mount`、`meta-magic_mount-rs`、`meta-mm`、`magic_mount` |
| Mountify | `mountify` |

面板「挂载」格显示 `Hybrid 托管` / `Magic 托管` / `Mountify 托管`，`status` 与日志里写全名并给出交付文件数。

各自的开关要注意：

- **Hybrid Mount**：`config.toml` 里若给本模块配了 `ignore`，文件不会被挂上去。需要放行：`[rules.quickcharge]` 设 `default_mode = "overlay"`（或 `magic` / `vfs`）。
- **Magic Mount**：`config.toml`（或 `mm.conf`）的 `partitions` 为空时按默认分区表走，已包含 `/system`、`/vendor`；只写了几个分区时要把 `vendor` 带上，否则 `/vendor/etc` 下的改写不会生效。
- **Mountify**：默认 `mountify_mounts=2`，自动挂载所有带 `system/` 的模块，无需配置；改成 `=1`（白名单模式）时要把 `quickcharge` 加进 `/data/adb/mountify/modules.txt`。在 Magisk / APatch 的非元模块模式下，Mountify 会往被挂模块的目录里写 `skip_mount`（防止原生挂载再挂一遍），当前环境里别删。

两点通用注意：

- 交付发生在 `post-fs-data`，它们的挂载在其后，**装完或改了配置要重启**才生效，不像 NoMount 能当场 reload。
- 判断依据是目录名，认不出来的新元模块仍走 `bind mount`，可能被覆盖。遇到就说一声，加一行名单即可。

**换元模块时清一下 `skip_mount`。** Magic Mount 与 Hybrid Mount 都会跳过目录里带 `skip_mount` 的模块，而 Mountify 在非元模块模式下会留下这个文件。从 Mountify 换到另外两家后，如果 `status` 显示「托管 N 个文件」但 `/vendor/etc` 下还是原版配置，先看这条：

```sh
su 0 sh -c 'rm -f /data/adb/modules/quickcharge/skip_mount'
```

托管模式下本模块只交付、不做内容校验，所以这类「交付了但没挂上」的情况在面板上不会报错，只能靠比对文件内容确认：

```sh
su 0 sh -c 'head -c 200 /vendor/etc/sys_thermal_config.xml'
su 0 sh -c 'head -c 200 /data/adb/modules/quickcharge/system/vendor/etc/sys_thermal_config.xml'
```

## 已知限制

- **`curr_max` 只能限流，不能加速。** 充电功率由适配器、协议、电芯内阻决定，改上限无效。真正能提速的是让温度反馈变低（壳温伪装）。
- **极速模式没有兜底。** 3.1.0 起恒定伪装：不看真实读数、不设档位、不设温度墙、不设熔断。撞到硬件保护就是撞到，模块不会自动退让——这是拿平滑曲线换速度的取舍。
- **节点名因机型而异。** `shell-back` / `xo-therm` 这类名字不是所有机型都有；MTK 又是另一套
  `mtktsbattery` / `mtktscpu`。温区判断已改为按语义分类，匹配不上时仍会退化为"只挂配置"，
  日志里会有 `sentinel=none`。
- **SELinux。** 覆盖文件的上下文先按 `chcon --reference` 继承，失败再从原件的 `ls -Z` 取
  `u:object_r:xxx:sN` 显式设置（toybox 的 chcon 不认 `--reference`，这一步是常态而非异常）。
  两条都不成会汇总成一条 `W` 日志，接着尝试挂载；系统服务仍拒绝访问时先查这条，
  也可用 `SD_CTX_OVERRIDE` 强制指定。3.0.12 之前的版本在这里是全数失败。
- **只骗得过读 `thermal_zone` 的软件层。** 内核级热保护、硬件断电保护不受影响，这是好事——它是最后一道防线。
- **压得越狠，越容易撞上硬件保护。** 伪装温度压到 25℃ 时，系统会按"电池很凉"继续给 60-80W，
  而充电 IC 与电池保护板读的是自己的 NTC，到 42-45℃ 会自行降流甚至短暂停充，表现为功率在
  满功率与 10-20W 之间反复跳（锯齿）。模块改不了这条链路。想平滑一点就把伪装温度调到 30-33℃，
  而不是等硬件来切。3.1.4 起新装默认 30℃，升级不动用户已有的值。
- **软件侧的锯齿（2.9.0～2.9.3，已修）。** 这两版把充电 IC / PMIC 也算进了熔断候选。100W 机型
  充电时充电 IC 自己就在 85℃ 上下，于是熔断被反复触发：撤销伪装 → 系统看到真实的 42℃ 立刻
  降到 10-20W → 芯片凉下来 → 恢复伪装 → 又满功率。周期几十秒，曲线正是用户说的"波浪"。
  2.9.4 起候选回到「电池类 + `xo-therm`」，与 2.7.x 一致；天玑的 `mtk-battery` 仍由电池类覆盖。

## 极速模式：一条路走到底

3.1.0 起不再有档位、温度墙、熔断、绝对限流这一整套退让逻辑，只剩一件事：插着电就把伪装温度
恒定写下去。旧版那套 100 / 75 / 50 / 25% 四档降流、`wall` / `curr_max` / `curr_edge` / `aggr`
全部移除，`state.conf` 里的残留键在升级时自动清掉。

代价写清楚：没有兜底。真实电池到 42-45℃ 时，充电 IC 与电池保护板会按自己的 NTC 降流甚至
停充，模块这边看不到也管不了，表现出来就是功率上下跳。想减少这种情况，只能把伪装温度往
30-33℃ 调，让系统自己早一点软降档。

## 屏幕快充（内置常开，没有开关）

一加/OPPO 的内核在屏幕亮起时会把最大充电电流（FCC）压到 `SCREEN_ON_MAX_FCC_MA`，
常见值是 1500～2000mA，也就是 **7～9W**。这一步发生在充电驱动的 `fb_notifier` 里：

```c
case FB_BLANK_UNBLANK:
    chip->screen_on = 1;
    reset_max_fcc_ma(chip, SCREEN_ON_MAX_FCC_MA, true);
```

它跟温度无关——36℃、电池很凉也照样压。这就是"息屏能快充、亮屏只剩 8W"的来源。
调温度墙、调壳温都没有用，因为限流点根本不在温控那一层。

反过来的方向也得管，但方向不能反：息屏那一刻驱动会重算 FCC，那正是它把电流
放开到协议允许峰值的窗口。模块如果在息屏继续写回基准，等于替驱动踩刹车——写进
去的是历史值而不是驱动此刻愿意给的电流，60W 机型直接掉到 30W 档；压住之后驱动
不再重算，下轮 `learn` 读到的还是低值，基准也永远学不到真实峰值。

2.9.64 只在亮屏写，所以正常；2.9.73 为了让"息屏也保持亮屏设置"把这层判断删了，
3.0.0~3.0.4 沿用，于是出现"2.9.64 好好的，新版本锁 30W"。3.0.5 的正确做法是
**息屏彻底不写**，把 FCC 交还驱动；"息屏保持"只由内核 `ignore_screen_state` 承担。

模块默认就接管，没有开关：

1. 内核有 `ignore_screen_state` 参数 → 写 `1`，让驱动不再看屏幕状态，这在语义上
   就是"息屏保持亮屏设置"；息屏这一轮还原为 0，交给驱动走正常 FCC（切「关闭」模式、
   拔线或熔断同样还原）；
2. 没有该参数 → 息屏只记录 FCC 峰值（`learn`），**不写节点、不还原**；亮屏后驱动把
   FCC 压到屏幕档，模块按峰值顶回去。只有被压到目标的 3/4 以下才写，避免和驱动的
   动态计算拉锯。

要整体停掉，把「温控改写范围」切到「关闭」——那个模式下模块不碰系统任何东西，
屏幕快充也一并不接管。面板上不显示这项，接管状态用命令看：

```sh
su 0 sh -c 'sh /data/adb/modules/quickcharge/action.sh status | grep 亮屏快充'
```

状态行仍叫「亮屏快充」，方便和旧日志对照；FCC 路径息屏显示"息屏交还驱动（下次亮屏
再接管）"，内核参数路径显示"息屏保持"。

| 项 | 行为 |
|---|---|
| 生效条件 | 有线充电中 + 熔断未触发 + 电池 ≤46℃ + 没有同时开 `curr` 限流 |
| 息屏（内核参数） | 还原 0，交给驱动；"保持亮屏设置"由参数语义本身承担 |
| 息屏（FCC 路径） | 只学峰值，不写节点、不还原，完全交还驱动 |
| 电池 38～46℃ | 不再打折，回写值就是基准 |
| 电池 ≥47℃ | 完全不接管，立即还原（亮屏息屏同一道闸） |
| 与限流同时开 | 限流优先，屏幕快充不接管（两个都写同一节点会互相覆盖） |
| 退出条件 | 拔线 / 熔断 / 切到「关闭」模式，下一轮立即还原 |
| 本机不支持 | 面板显示"本机不支持" |

### 写入型节点：先证明"需要写"再写

3.0.6 起，凡是会让驱动重新选档的节点（`cool_down`、FCC 回写），写之前都要先读
当前实测值，确认真的被压了才动手：

| 节点 | 触发条件 | 判据 |
|---|---|---|
| `cool_down` 写 0 | 只在被降流时 | `ibat ≥ 2.5A` 视为未降流，直接返回 |
| FCC 回写 | 只在亮屏且被压时 | `cur ≥ 目标 × 3/4` 不写 |

反例（都在这台机上复现过）：`ibat` 4.3A 时写 `cool_down 2→0`，三秒后 18W 掉到
9.7W；`ibat` 3.6A 时写 `0→1`，协议从 7 退到 14，32W 掉到 9W。两次掉档都不是值的
问题，是写入这个动作让 OPlus 重新协商。旧逻辑只比"值不同"就写，等于自己把好机器
打成降流。

### 回写目标只能是电池侧节点

3.0.3 及更早把 `usb/current_max` 当成 FCC 的兜底候选，这是错的。它的语义是
**USB 端口能力上限**（PD 协商用，插电前常见就是 2000mA），不是电池充电电流。
往里写字会让充电器重新协商，实测 OPPO Find X8 从 60W 掉到 37W，一加 12 停在 33W：

```
17:48:22  pb=60.4W          ← 原装快充正在爬坡
17:48:25  回写 FCC 目标 2000mA  ← 模块写的
17:48:28  pb=37.9W          ← 掉档，之后一直 37-40W
```

所以 3.0.4 起回写目标只认 `battery/constant_charge_current_max`、
`battery/current_max`、`oplus_chg/battery/chg_current_max` 这类**电池侧**节点；
`usb/`、`charger/`、`pc_port/`、`wireless/`、`input_current_limit` 全部排除。
一个电池侧节点都找不到时判定"本机不支持"，什么都不写——宁可不管，也不能打断快充协商。

同理，基准值现在绑定节点名（`run/fcc.node`）：节点换了就作废旧基线重学，
不会拿 usb 端口的历史 2000mA 去压电池侧的 6000mA。

**走回写 FCC 那条路的机型，要先息屏充一次。** 模块需要在那时记下正常的 FCC 作为基准
（`run/fcc.norm`），亮屏后才能知道"该写回多少"。没有基准时面板会提示，
不会瞎猜一个电流值。有 `ignore_screen_state` 的机型不需要基准，开机充电即接管。

**47℃ 那道闸两条路共用。** 内核参数一写就是「永远不看屏幕」，电池发烫时更不能开，
所以充电中（亮屏或息屏）电池到熔断前 1℃ 时，无论走哪条路都先还原、暂停接管，
温度降回来自动恢复。

**为什么不直接写死一个大电流。** 100W 机型的 FCC 能到 10A，33W 机型只有 3A，
写死任何一个值都会要么没效果、要么过流。用息屏时的实测值做基准，是唯一
不依赖机型参数的做法。

**息屏不再 +2℃。** 3.0 起亮屏、息屏共用同一条墙。以前夜里给息屏加 2℃ 的余量，
代价是「一熄屏功率反而掉」，而实际风险由熔断兜底。

判据来自 `/sys/class/backlight/*/actual_brightness`（没有该类时退到
`/sys/class/graphics/fb0/blank`），一次 read、零 fork。不用 `dumpsys power`：
15 秒一次的 fork 太贵，而且 KernelSU / APatch 的域经常连不上 power 服务。

## 配置改写：目录、开关与自检

只扫这 7 个目录（`-maxdepth 2`）：`/vendor/etc`、`/odm/etc`、`/my_stock/etc`、
`/my_product/etc`、`/system/vendor/etc`、`/system/system_ext/etc`、`/vendor/qti/etc`。
`/my_stock` 与 `/my_product` 是 ColorOS 14+ 放温控表的地方，3.1.4 起纳入。

`charging_*.txt` 改写前做列语义探测：首列必须在 0~600（0.1℃ 量级）且单调不减，
否则整份跳过并在日志记 `跳过改写(格式不符)`。这样不会把 +12℃ 加到电流列上。

生成后跑一次自检：高温保护 XML 里不应再有 `="true"`，充电表行数应与原件一致，
不符合记 `W`。日志里每个目录还有一行命中数（`改写 / 跳过 / 失败`），
排查「没扫到」还是「改坏了」先看这几行。

需要区分「是配置改写的锅还是伪装的锅」时：

```sh
su 0 sh /data/adb/modules/quickcharge/action.sh overrides off   # 只卸配置层
su 0 sh /data/adb/modules/quickcharge/action.sh overrides on    # 恢复
```

`overrides off` 会卸掉 bind mount、清空 NoMount 镜像与清单；温度伪装走
`emul_temp`，与配置层无关，照常工作。

## 极限功率：`batt_spoof`、`unlock` 与 CPU 伪装

这三项是**唯一会越过模块安全设计**的开关，都在面板「极限功率」卡里，默认关闭，
开启时弹确认。它们解决的是"系统因为怕热而提前收手"，不是"让充电器多给电"。

```sh
su 0 sh -c 'sh /data/adb/modules/quickcharge/action.sh batt 30'   # 电池温区按 30℃ 上报
su 0 sh -c 'sh /data/adb/modules/quickcharge/action.sh batt off'  # 交回真实
su 0 sh -c 'sh /data/adb/modules/quickcharge/action.sh unlock on'  # 解除阶梯限流
```

### `batt_spoof`：为什么可以开，又为什么有硬上限

电池温区（`battery` / `batt*`）本来是哨兵，不参与伪装。开启后它和 core 温区一样被
bind mount 覆盖，系统读到的电池温度变成你设的值。

关键设计是**分成两路采样**：

| 采信来源 | 用途 | 受伪装影响 |
|---|---|---|
| `thermal_zone*/temp`（battery 类） | 系统/温控服务判断 | **是**，读到的是设定值 |
| `power_supply/battery/temp`（充电 IC ADC） | 熔断判断、硬上限、面板「真实」 | **否**，永远是真实值 |

所以伪装期间熔断依旧有效：`sd_sentinel_best_v` 一旦看到 `batt_spoof` 生效，就不再读
温区，改读 `power_supply`。这也是为什么**不要试图去伪装 `power_supply/battery/temp`**——
那是最后一条真实线路，关掉它熔断就真的瞎了。

硬上限 46℃ 写死在代码里（`SD_BATT_HARD`），不开放给用户调：真实电池到 46℃ 就撤销
电池伪装并冷却 120 秒，期间即使开关还开着也不会重新伪装。读不到 `power_supply` 温度时，
`batt` 命令直接拒绝开启，守护也会在下一个 tick 关掉它——不猜安全。

**这只影响温区，不影响充电 IC 的硬件 JEITA。** 欧加的充电驱动读的是 `power_supply` 的
ADC，不是 thermal zone。所以：

- 能拿到：thermal-engine / HAL 不再因为"电池 42℃"而压低电流或降频；
- 拿不到：充电 IC 自己的高温保护、CV 阶段降流、适配器协议功率。

想让「电池 45℃ 还满功率」，靠这个开关做不到——那需要改 `charging_*.txt` 的曲线，
本模块不做。

### `unlock`：取消充电阶梯限流

充电的「阶梯」来自两处，都不是 horae：

| 来源 | 节点 | 谁在写 |
|---|---|---|
| 系统 thermal HAL | `battery/charge_control_limit`、`thermal_charging`、`step_charging` | vendor 的 thermal-engine / HAL |
| 充电驱动自己分档 | `oplus_chg/battery/cool_down`、`constant_charge_current_max` | `oplus_chg` 驱动按电池温度 |

`unlock on` 只动第一类：把这些节点写 0（= 不限流），写之前把原值存进
`run/unlock.orig`，`unlock off` / 超温 / 卸载时逐行还原。

刻意不碰两处：

- `usb/current_max`：那是输入侧能力上限，写它会打断 PD/VOOC 协商（3.0.4 的教训：
  写它之后 60W 掉到 37W）；
- `cool_down`：写它会让 OPlus 重选档。PKB110 实测 `ibat` 4.3A 时写 `2→0`，三秒后
  18W 掉到 9.7W。这个节点交给 `sd_cool_tick`，只在确实被降流（<2.5A）时写。

**安全边界**：电池真实温度（`power_supply/battery/temp` 的 ADC，不是温区）≥45℃
立刻撤销并还原，读不到温度也撤销——不猜。这条兜底写在 `sd_unlock_tick` 最前面，
先于任何写入。

3.0.8 删掉了原来的 `thermal` / `horae` 开关。它只在做
`setprop persist.sys.horae.enable` + `stop horae`，管的是 CPU/GPU 降频、亮度、
限帧，跟充电电流没有关系；留在 UI 里只会让人以为能解决掉功率。

### 收益的真实边界

按对充电速度的实际影响排序：

| 手段 | 收益 | 代价 |
|---|---|---|
| 壳温伪装（默认 30℃） | 高，充电策略看到的是凉机身 | 真实温度仍在涨，硬件保护会先切 |
| `unlock on` | 中，HAL 侧不再按温度压流 | 机身更热，≥45℃ 自动撤销 |
| `batt_spoof` | 中低，仅对读温区的策略有效 | 电池长期高温，寿命与安全 |
| 抬浮充电压 | 高（多 4～6% 容量） | **本模块不做**，需改 dtbo，不可回滚 |

实际电流由适配器、线材、电量、温度共同决定，模块能做的只有两条：让充电策略
读到的壳温更低（`emul_temp`），以及在确实被降流时把 `cool_down` 写回 0。

## 2.9.6：掉功率的三条真实路径

现象：温度离墙还远，功率已经掉了；满功率只维持一瞬间；电流一档一档往下掉再爬回来。
这一版修的是模块自己造成的两条，第三条是系统行为，只能靠 `diag` 判读。

| 路径 | 触发条件 | 现象 | 处理 |
|---|---|---|---|
| 限流档位提前太早 | 设了 `curr_max`，墙 42℃ | 34℃ 就砍到 75%，此后 39/41℃ 再各砍一次 | 档位改为 38/40/42℃，36℃ 以下全程满功率 |
| 阈值上缺回差 | 温度在阈值附近抖 0.1℃ | 100%↔75% 每 tick 来回切，充电 IC 反复重协商 | 降流即时，恢复要低 1℃ |
| 充电 IC 自身保护 | 满功率持续几十秒 | 电池才 35℃，`charger-therm` 已 80℃+，系统砍档 | 模块不伪装这一路（故意），只能降 `curr_max` 或降档位 |
| 核心伪装压住 SoC 温度 | `core 30` 之类 | 系统以为 CPU 凉，放开调度；真实功耗抢走充电功率 | 充电时建议 `core off` |

`wall off` 的语义后来也统一了：3.0 起 `off` 与 `60` 等价，都是「不设墙」，
按熔断前 1℃ 处理，不再有单独的 44℃ 联动线。

核心/非核心伪装的写入单位改成按节点实测编码换算。读侧一直支持 mC / 0.1℃ / ℃
三种，写侧过去一律写 mC —— 碰到 0.1℃ 编码的温区，写 30000 等于告诉系统 3000℃，
结果是插上瞬间满功率、随后被系统按严重过热砍到最低档，再也上不去。

### 排查：`diag`

```sh
su 0 sh -c 'sh /data/adb/modules/quickcharge/action.sh diag 180'
```

插着电跑 3 分钟，输出在 `/sdcard/Download/qc-diag-*.txt`。每 2 秒一行：

```
[  12s] Charging  电池  36℃   7800mA   8900mV    69W  限流 目标5500mA(100%)
        core : cpu-0-0=30(真实58)* gpu=30(真实54)*
        board: xo-therm=41 charger-therm=78
```

带 `*` 的节点已经被伪装顶成固定值，括号里是伪装前记下的真实温度。
判读顺序：

1. 电池温度远低于墙、限流已 `<100%` → 档位触发点问题（2.9.6 已修）
2. 电流周期性掉到同一档再爬回 → 阈值来回跨档（2.9.6 已加回差）
3. `core` 全是固定值且电流长期偏低 → 核心伪装让系统放开 CPU，建议关掉
4. `charger-therm` 接近 80℃ 而电池才 35℃ → 系统按充电 IC 保护降档，与温度墙无关

## 2.9.5 修的隐性缺陷

这一版没有新功能，全部是"不报错、但结果是错的"的路径。逐条留档，便于日后回归：

| 现象 | 原因 |
|---|---|
| 温度降了，限流不回抬 | `sd_curr_keep` 只压不抬，节点停在最低档 |
| 关掉限流实际还在限 | 只改 state，没还原节点；现在按 `curr.orig` 还原 |
| 熔断后功率抖 | 复查把"读不到"当成"已降温"，解开又立刻熔断 |
| 无电池节点时永久熔断 | 兜底候选选中 WiFi / PA，它们正常就 90℃+ |
| 天玑机型功耗曲线全空 | `status` / `capacity` / 电流 / 电压只认 `battery/` |
| 电芯数显示成 4400000 | `sd_ps_attr_v` 把微伏值留在 `_sd_rv` 里没复位 |
| 关掉强制锁帧后视频不降帧 | 系统原本没有 mcfr 键时记成空，还原逻辑当成"没开过" |
| 改 `curve_offset` 重启不生效 | 覆盖层指纹只看 ROM，不看参数与模块版本 |
| 心跳一直是"上一次开机" | 部分环境 `read </proc/uptime` 返回空，已加 cat 兜底 |
| 两个滑块同时提交丢一个 | 状态文件读-改-写无互斥；现在 mkdir 加锁 |

## 性能

2.9.43 起热路径重写了一遍。主要开销不在 shell 解释执行，而在 `fork`：
旧实现每个节点的温度值都用 `$(tr -d ' \t\r\n' < 节点)` 取，一次 tick 要起
**41 个进程**（其中 36 个是 `tr`）。改成 `read` 内建后降到 **4 个**（只有首轮
`getprop` 那三次）。

容器实测（8 温区 + 完整电池节点，200 轮均值）：

| 指标 | 2.9.42 | 2.9.43 shell | 2.9.44 shell | 2.9.44 C |
|---|---|---|---|---|
| 每 tick CPU | 9.4 ms | 1.3 ms | 1.3 ms | **0.14 ms** |
| 每 tick fork | 41 | 4（首轮后 1） | 4（首轮后 1） | **0** |
| 常驻内存 | 3-5 MB | 3-5 MB | 3-5 MB | < 1 MB |
| 日均 CPU（tick=15s） | 约 54 秒 | 约 7 秒 | 约 7 秒 | 约 1 秒 |

C 版的 0.14 ms 是 x86 容器实测；arm64 在 qemu 用户态下 0.42 ms，而 qemu 有 3-10 倍
解释开销，真机落在 0.1-0.2 ms。功能上 2.9.44 的 C 版比 2.9.43 多做了一圈
（壳温动态上报、电池伪装、熔断恢复、遥测、高刷），耗时反而更低——省掉的是
每轮 `umount`/`mount`：目标值没变就直接返回。

真机是 ARM + mksh + toybox，fork 比容器贵 2-5 倍，实际差距更大：
shell 版大约从「3-8 分钟/天」降到「1-2 分钟/天」，C 版在 10 秒量级。

其余几处优化（2.9.x 早期就有）：

1. **`settings` 一次取两个键。** 锁定高刷时一次 `settings list system` 筛出两个键，
   不再每 tick 起两个 `app_process`。
2. **日志只在变化时写。** 上报温度变了才记，另加 15 分钟兜底，稳定工况约 96 行/天。
3. **温区表缓存。** `type` 只在启动扫一次，之后每 40 tick 重扫。
4. **`sleep & wait`。** `wait` 是内建，收到 TERM 立刻退出，不用等满一个 tick。

想进一步降耗就把 `tick` 调到 30 或 60 秒；改参数靠 SIGUSR1 唤醒，只影响
「系统自己变了」这类被动场景的响应速度。

## 目录结构

```
quickcharge/
├── module.prop
├── customize.sh        安装：设备检测、生成覆盖层、初始化参数
├── post-fs-data.sh     开机早期：挂载覆盖层，OTA 后自动重建
├── service.sh          开机后期启动守护，检测到 bin/qcmon 就交给 C 版
├── action.sh           控制入口：CLI + 交互菜单
├── uninstall.sh        卸载：停守护、卸挂载、归零、清数据
├── webroot/index.html  WebUI（纯静态，KernelSU / MMRL / KsuWebUI 加载）
├── lib/qc.sh           核心库：配置改写 / 温度伪装 / 充电，单文件
├── bin/qcmon           C 守护（静态 aarch64，仅 C 版包含）
├── src/qcmon.c         C 守护源码（不打包，脚本版包里也没有）
├── build-qcmon.sh      编译脚本：sh build-qcmon.sh [x86]
├── docs/TECH.md        本文件（不打包）
├── tests/              冒烟测试：c-test / chg-unit / cool-unit / state-unit / sim
└── META-INF/...
```

`files/` 是安装时生成的覆盖层（不在包里，包内只是个空占位目录），存放改写后的配置副本，
没有元模块时 bind mount 到系统分区；检测到 Hybrid Mount / Magic Mount / Mountify 时，
同一份副本会再交付到 `system/`（也是运行时生成），由它们自己挂。如果模块目录只读
（模块被放在只读分区），自动回落到 `/data/adb/quickcharge/overrides`。

## 卸载

在管理器里卸载即可。卸载脚本会停守护、卸全部挂载、把 `emul_temp` 写 0、还原限流节点原值与刷新率设置、删除数据目录。

高刷锁定会动三处：`peak_refresh_rate`、`min_refresh_rate`、`match_content_frame_rate`，外加 `cmd display set-match-content-frame-rate-policy`。卸载时四样一起还原——原本没有 `match_content_frame_rate` 这个键的机器会删掉它并把策略写回 2，不是留着 1 让视频永远跑 24/30fps。

想先手动确认：

```sh
sh /data/adb/modules/quickcharge/action.sh umount   # 只卸配置覆盖
grep -c thermal_zone /proc/mounts                   # 应为 0
```

卸载后重启一次最干净。

## 许可

本项目源码完全公开：可自由查看、修改、分发，许可证为 **GNU General Public License v3.0**，
全文见 [LICENSE](LICENSE)。

Copyright (C) 2026 QuickCharge contributors

**禁止商业用途，禁止用于任何违反法律法规的场景。** 需要商用请先联系作者取得授权。
