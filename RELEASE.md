# Quick Charge v3.0.7

用户反馈「停用热管理并不能取消阶梯充电，好像这个开关根本没有作用」。观察是对的：
`thermal off` 从来就没管过充电，是文案把它写成了总开关。

## `thermal off` 实际做了什么

```sh
sd_horae() {
    case "$1" in
        1) setprop persist.sys.horae.enable 1; start horae ;;
        0) setprop persist.sys.horae.enable 0; stop horae ;;
    esac
}
```

两行，到此为止。`horae` 是欧加的性能温控服务，管 CPU/GPU 降频、亮度、部分场景限帧；
充电电流不归它管，停了自然一点变化都没有。

充电的「阶梯」来自另外两处：

| 来源 | 节点 | 谁在写 |
|---|---|---|
| 系统 thermal HAL | `battery/charge_control_limit`、`thermal_charging` | vendor 的 `thermal-engine` / `thermal` HAL |
| 充电驱动自己分档 | `oplus_chg/battery/cool_down`、`constant_charge_current_max` | `oplus_chg` 内核驱动，按电池温度 |

这两条路径都不经过 horae，所以 `thermal off` 对它们零影响。

## 3.0.7 改了什么

**1. 文案不再骗人**

- `status`：`热管理 已停用（horae 停止）` → `horae 已停（只管性能/亮度，不影响充电阶梯）`
- `thermal off` 输出后追加一行提示，指向 `tiers`

**2. 新增 `tiers`：充电阶梯诊断**

把能左右充电电流的节点一次列全，带当前值、是否可写：

```
  node                                   value       wr   note
  battery/charge_control_limit           0           yes  thermal HAL 额外限流，0=未限
  battery/charge_control_limit_max       3000mA      yes  thermal HAL 可写到这个上限
  battery/thermal_charging               1           yes  1=系统温控正在限充
  battery/constant_charge_current_max    4000mA      yes  电池侧 FCC，驱动当前允许值
  usb/current_max                        2000mA      yes  输入侧上限，写它会打断 PD/VOOC
  oplus/cool_down                        7           yes  亮屏降流档，0=不降
```

跑一次就知道本机是谁在限：`thermal_charging=1` 是系统 HAL，`cool_down>0` 是驱动分档，
`constant_charge_current_max` 直接就是驱动此刻允许的电流上限。

**3. 文档同步**：README 与 `docs/TECH.md` 明确 horae 的边界，不再叫「系统热管理总开关」。

## 想真的不按温度降

现有手段是 `batt <℃>`（伪装电池温区，默认关，真实 ≥46℃ 自动撤销）：

```sh
sh action.sh batt 32
sh action.sh diag 60
```

能不能生效取决于本机驱动是否读 `thermal_zone` 的电池温区。如果伪装后 `ibat` 不回升、
`tiers` 里 `thermal_charging` 仍是 1，说明限流在驱动内部或 HAL 层，伪装温度碰不到——
把 `tiers` 的输出发出来，下一版按实际节点做定向解锁。

## 版本号

`3.0.7` / `versionCode 300015`。

## 验证

shell 仿真 670 项、C c-test 94 项、`chg` 44 / `cool` 20 / `state` 12 / `mount` 4 全过。
新增断言覆盖 `tiers` 的三类节点与 status 文案。
