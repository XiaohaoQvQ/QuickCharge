# Quick Charge v3.0.8

按反馈删掉「停用系统热管理（horae）」这个开关，换成真正作用于充电的阶梯解锁。

## 为什么删

`thermal off` 从头到尾只做两件事：

```sh
setprop persist.sys.horae.enable 0
stop horae
```

`horae` 是欧加的性能温控服务，管 CPU/GPU 降频、亮度上限、部分场景限帧。它跟充电
电流没有任何关系，所以「停用热管理」停不掉阶梯降流——这个开关从一开始就不该叫
这个名字，也不该放在「极端功率」卡里。

## 换成了什么

**1. `unlock on|off`：取消充电阶梯限流**

写 0 到 thermal HAL 的限流节点：

| 节点 | 含义 |
|---|---|
| `battery/charge_control_limit` | HAL 额外限流，0 = 不限 |
| `battery/thermal_charging` | 1 = 系统温控正在限充 |
| `battery/step_charging` | 阶梯充电开关（部分机型有） |

写之前把原值存进 `run/unlock.orig`，`unlock off`、超温、卸载时逐行还原。

**刻意不碰两个节点**：

- `usb/current_max`：输入侧能力上限，写它会打断 PD/VOOC 协商（3.0.4 的教训）；
- `cool_down`：写它会让 OPlus 重选档。PKB110 实测 `ibat` 4.3A 时写 `2→0`，三秒后
  18W 掉到 9.7W，交给 `cool_tick` 只在真被降流时写。

**安全兜底**：电池真实温度 ≥45℃ 立刻撤销并还原；读不到真实温度也撤销，不猜。

**2. 面板开关换成「取消充电阶梯限流」**，文案不再提热管理。

**3. `tiers` 保留**，用于看清本机是 HAL 在限还是驱动在分档。

## 老用户

升级后开机，`post-fs-data` 会检查旧状态里的 `horae=0`，是的话把它恢复成系统默认
（`persist.sys.horae.enable=1` + `start horae`），然后删掉这行状态。功能入口没了，
不能把 horae 一直停在关闭状态。

## 版本号

`3.0.8` / `versionCode 300017`。

## 验证

shell 仿真 681 项、C c-test 101 项、`chg` 44 / `cool` 20 / `state` 12 / `mount` 4 全过。
新增断言：`thermal` 命令已移除、`unlock` 默认关闭、写 0 与备份、46℃ 拒绝开启、
开启后升温自动撤销并还原。
