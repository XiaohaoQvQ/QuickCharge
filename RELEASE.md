# Quick Charge v3.0.4

修「功率锁在 30W」：屏幕快充的回写目标选错了节点，写 `usb/current_max` 会让充电器
重新协商，把已经爬到 60W 的快充打回 37W。

## 现象

两位用户反馈，原装充电器也充不快，功率稳定在 30W 出头，怎么调温度墙都没用。

## 日志里的证据

OPPO 机型（3.0.2-c，MTK）的时间线：

```
17:48:19  pb=35.0W    imax=1.30A
17:48:22  pb=60.4W    imax=1.30A   ← 原装快充正在爬坡
17:48:25  亮屏快充：已接管（回写 FCC，目标 2000mA）
17:48:28  pb=37.9W    imax=2.00A   ← 掉档，之后一直 37-40W
```

一加机型（3.0.2-c，骁龙 8 Gen 3）同样卡在 8.3V/4A ≈ 33W，`fcc 节点` 也是
`/sys/class/power_supply/usb/current_max`。

## 原因

`usb/current_max` 是 **USB 端口能力上限**，PD 协商用，插电前常见值就是 2000mA，
不是电池充电电流。把它当 FCC 目标有两个后果：

1. 基线学到的就是 2000（插电前的默认值），接管时把 2000 写回去；
2. 这个写入会触发充电器重新协商，直接掉档——就是上面那段 60W → 37W。

有些机型没有电池侧电流节点（两台日志里一台 `charge-nodes=1`，只剩 usb），旧代码
就一路兜底到它，于是「接管」变成了「限流」。

## 修复

- 回写目标只认电池侧节点：`battery/constant_charge_current_max`、`battery/current_max`、
  `oplus_chg/battery/chg_current_max`；`usb/`、`charger/`、`pc_port/`、`wireless/`、
  `input_current_limit` 全部排除；
- 一个电池侧节点都没有时判定「本机不支持」，**什么都不写**——宁可不管，也不能打断协商；
- 基准值绑定节点名（`run/fcc.node`），换节点就作废旧基线重学，不会拿端口的历史
  2000mA 去压电池侧的 6000mA；
- `action.sh status` 与日志文案改成「本机不支持（无屏幕状态参数，也没有电池侧电流节点）」。

绝对限流（`action.sh curr`）仍然写 `usb/current_max`，那是用户主动限流，不影响快充协商。

## 影响

- 有电池侧节点的机型（一加/多数高通）：屏幕快充照常接管，目标值来自电池侧真实电流；
- 只有 `usb/current_max` 的机型（部分 OPPO/MTK）：屏幕快充不再接管，但功率不会再被
  模块打断，充电曲线交回系统。

## 版本号

`3.0.4` / `versionCode 300009`。C 版同步发布 `3.0.4-c` / `300008`。

## 验证

- shell 仿真 658 项、机型矩阵 69 项、C c-test 90 项全过；
- `chg` 44、`cool` 20、`state` 12、`mount` 4、`zone-rank` 6 全过；
- 节点选择实测：`battery` 与 `usb` 同时存在时选 battery，只剩 usb 时返回不支持。
