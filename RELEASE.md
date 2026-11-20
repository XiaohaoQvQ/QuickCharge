# Quick Charge v2.9.62（shell 版）

> 对应包：`QuickCharge-v2.9.62.zip` · `versioncode 29605`

面板一直写着「PD 快充」，拔掉充电器也还写着。是两个判断错误叠在一起，
这一版都改了；另外包含 2.9.61 删掉「充电限流」显示那一处。

## 一、没插充电器不再显示 PD

`usb/voltage_max` / `usb/current_max` 报的是**端口能力上限**，不是当前协商结果。
拔线后这两个值常驻 `5V` / `500mA`（标准 USB SDP 的默认值），旧逻辑看到 `v>0`
就落到 PD，于是「PD 5V/500mA」一直挂在面板上，日志里也是这么写的。

现在先判适配器在不在位，顺序是 `usb/online` / `usb/present` → 实测输入
（≥4V 且 ≥100mA）→ 电池状态（`Charging` / `Full`）。不在位直接 `proto=none`，
面板显示「未接充电器」，日志写 `proto=none（未接适配器）`。

## 二、没有协议字样时不再猜 PD

旧兜底是 `v>0 || c>0 → pd`。可 9V/2A 既可能是 PD 固定档，也可能是 VOOC 掉档后的
样子（`tech` 从 7/8 跳到 14 就是这种现场），一律标 PD 会误导：插的是原装头，
却被告知在用 PD。

现在的判定顺序：

| 顺序 | 依据 | 结论 |
|---|---|---|
| 1 | `type` / `real_type` 含 `VOOC`/`SVOOC`/`DART`/`Flash` | 私有 |
| 2 | `voocchg_ing = 1` | 私有 |
| 3 | `charge_technology` 1~13 | 私有（`tech=N`） |
| 4 | `charge_technology` ≥14 | PD（`tech=N（私有档已退）`） |
| 5 | 协商 `v≥8V` 且 `c≥5A` | 私有（协商值） |
| 6 | 其余 | `unknown` + 协商值，不挂标签 |

日志里能直接看到依据：

```
proto=vooc（tech=8）
proto=pd（tech=14（私有档已退））     ← 真的掉档了，这时显示 PD 是对的
proto=unknown（协商 9V/2000mA，无协议字样）
```

## 三、面板

`proto=none` 时，「实时功耗」标题右侧显示「未接充电器」；`unknown` 不挂标签，
不给没有依据的结论。

## 验证

| 套件 | 结果 |
|---|---|
| `chg-unit` | 51 通过（新增 6 条：拔线 none、无输入 none、9V/2A 不猜 PD、tech=14 有依据） |
| `c-test` | 81 通过（新增 4 条，同上） |
| `cool-unit` | 16 通过 |
| `mount-unit` / `zone-rank` | 4 / 6 通过 |
| `sim` | 621 通过 |

## 如果还显示 PD

插上充电头，把日志开到「详细」，看 `proto=` 后面的括号：

- `tech=14（私有档已退）` —— 协议真的退了，多半是降档或 `cool_down` 被写了值
- `tech=8` 却显示 `pd` —— 那才是判定还有 bug，把那一行发我
- `proto=unknown（协商 9V/2000mA，无协议字样）` —— 头是普通 PD 头，或者机型不报 `tech`

## 用法提醒

装上后先在面板点「详细」，复现一次问题，再点「关闭」。
日志在 `/data/adb/quickcharge/log.txt`，超过 512KB 自动轮转一份 `.old`。
