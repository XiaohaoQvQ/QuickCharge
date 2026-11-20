# Quick Charge v2.9.66（shell 版）

> 对应包：`QuickCharge-v2.9.66.zip` · `versioncode 29613`

两件事：「真实」下面直接写温度点；协议判定不再被 `usb/type` 里的 `USB_PD` 带偏。

## 一、「真实」格下的小字

| 以前 | 现在 |
|---|---|
| `守护读数 · batt` / `现场直读 · batt` | `batt` |

来源（缓存 / 现场直读）不再占位，只留真正在用的那个温度点。

## 二、协议一直被显示成 PD 的原因

欧加在私有协议在线时，`usb/type` 也可能写 `USB_PD`：充电器先做 PD 握手，再切到 VOOC，
但节点里的字符串停在前一步。旧顺序是「先看类型串」，一个 `USB_PD` 就直接判 PD 并返回，
后面的 `charge_technology=8` 根本没机会执行。

新顺序：

| 顺序 | 判据 | 结果 |
|---|---|---|
| 1 | `charge_technology` 1~13 | 私有 |
| 2 | `real_type`/`type`/`charge_type` 含 VOOC/DART/Flash | 私有 |
| 3 | `voocchg_ing=1` | 私有 |
| 4 | 类型串含 PPS / UFCS | 公有 |
| 5 | `tech≥14` | 公有（标注「私有档已退」） |
| 6 | 类型串含 PD | PD |
| 7 | 协商 ≥8V 且 ≥5A | 私有 |
| 8 | 其余 | `unknown`，不挂标签 |

关键点：`tech` 排在类型串之前；`tech≥14` 又排在 VOOC 字样与 `voocchg_ing` 之后——
降档瞬间 `type` 还可能留着旧值，这时不能因为 `tech=14` 就把它判成 PD。

类型串改成三个节点一起匹配。以前只取第一个非空值，`real_type=Unknown` 会把
`type=USB_DCP` 挡住，等于少读一个节点。

日志行同步加 `rtype=`，排查时能同时看到两个节点：

```
... tech=8 type=USB_DCP rtype=USB_PD ... proto=vooc
```

## 三、验证

新增回归用例（两套都加）：

| 用例 | 期望 |
|---|---|
| `type=USB_PD` + `tech=8` | `vooc` |
| `type=USB_PD` 且无 `tech` | `pd` |
| `real_type=SVOOC` + `tech=14` | `vooc` |
| `voocchg_ing=1` + `tech=14` | `vooc` |

`c-test` 83、`chg-unit` 53、`cool` 16、`mount` 4、`zone` 6、`sim` 621 全通过。
