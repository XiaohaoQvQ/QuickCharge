# Quick Charge v2.9.54（shell 版）

> 对应包：`QuickCharge-v2.9.54.zip` · `versioncode 29540`

修两个日志缺陷，都是在一份 26 分钟的真机日志里暴露出来的。守护的温控、充电策略没有改动。

## 一、未充电时快照刷屏

**现象**：灭屏待机 26 分钟，日志里写了 52 条快照，几乎全是这样：

```
22:04:15 vusb=0.00V imax=0.50A vbat=4.341V ibat=0mA 100% 33℃ ... Discharging
22:04:47 vusb=0.00V imax=0.50A vbat=4.366V ibat=0mA 100% 33℃ ... Discharging
22:05:18 vusb=0.00V imax=0.50A vbat=4.365V ibat=0mA 100% 33℃ ... Discharging
```

**原因**：判重比的是整行字符串，`vbat` 在几十 mV 范围内来回抖，每次都算"变化"。
设计写的"未充电且不变不写"实际上永远不会成立。

**改法**：判重分两套。

| 状态 | 判据 |
|---|---|
| 充电中 | 整行比较（电压电流在爬，每个变化都有意义） |
| 未充电 | 只比状态签名：状态、电量（按 5% 归并）、温度（按 2℃ 归并）、vusb、imax、type、cool、vooc、tech、屏幕 |

同样的待机，现在只有在插拔、亮灭屏、电量跨 5%、温度跨 2℃ 时才落一条。

## 二、`ibat` 恒为 0mA

**现象**：52 条快照里电池电流一条没变过，全是 `ibat=0mA`，而面板上功率显示 5-10W。

**原因**：快照取的是 `power_supply/battery/current_now`，灭屏后这个节点不刷新，
一直返回 0；面板走的是 `bcc_parms`，两个数据源不同步。

**改法**：电流按优先级取，全部换算成 µA：

```
bcc_parms（mA ×1000） → battery/current_now → bms/current_now → battery/current_avg
```

一个都读不到才显示 `?`。C 版（qcmon）补上了同样的 bcc 解析，之前它完全没有读 bcc。

## 顺带

快照读取从 7 次 `cat` 改成 `sd_read1`（shell 内建 read），每轮少 7 个进程。
热路径的 fork 开销本来就占大头，这一处省得不算小。

## 测试

| 套件 | 结果 |
|---|---|
| `chg-unit` | 22 通过（新增 6 条：签名判重 3 条、bcc 优先 3 条） |
| `c-test` | 67 通过（新增 2 条 bcc 断言） |
| `cool-unit` | 9 通过 |
| `zone-rank` | 6 通过 |
| `mount-unit` | 4 通过 |
| `sim` | 621 通过 |

## 升级

直接覆盖安装，配置、日志、已调参数全部保留。

- 2.9.53 → 2.9.54：`versioncode` 29530 → 29540

## 文件

| 项 | 值 |
|---|---|
| 大小 | 71,545 字节 |
| 文件数 | 18 |
| 最低要求 | Magisk / KernelSU / APatch 任一 |
| 架构 | 全架构（纯 shell，无二进制） |

## 校验值

```
966aeaf8ca3d7306377e90f8946ccc88cd321a728b51da983938cbdf66735544  QuickCharge-v2.9.54.zip
```

## 另一个版本

同版本另有 C 守护版 `QuickCharge-v2.9.54-c.zip`，`chg_snapshot` / `chg_line` 做了同样的修改，
并补上了 bcc 直读。两版功能等价，详见 [QuickCharge-C](https://github.com/XiaohaoQvQ/QuickCharge-C)。
