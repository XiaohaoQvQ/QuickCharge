# Quick Charge v3.0.6

接着 v3.0.5 查「功率只有十几 W、还越来越低」。结论是：这台机根本没有走 FCC 回写，
3.0.5 的改动静默不生效；真正让功率掉档的是**写 `cool_down` 这个动作本身**。

## 日志里的证据（OPPO PKB110，MT6991，3.0.5-c）

```
19:32:30  charge-nodes=1
19:32:30  fcc 节点=none（只有输入侧节点 usb/current_max，不接管）
19:34:35  vusb=8.74V iusb=?A imax=2.00A vbat=4.221V ibat=-4277mA pb=18.1W
19:34:57  降流解除：cool_down 2 → 0（电池 38℃ 电量 60%）
19:35:00  vusb=8.63V ibat=-2337mA  pb=9.7W     ← 三秒后掉档
19:35:05  vusb=8.51V ibat=-2454mA  pb=10.2W
19:36:47  vusb=8.41V ibat=-1491mA  pb=6.4W
19:36:53  vusb=8.73V ibat=-136mA   pb=0.6W
```

三件事需要分清：

1. `fcc 节点=none`、`curr_max=0`，模块这轮**没有写任何电流节点**，3.0.5 的「息屏不
   回写 FCC」对它完全不适用；
2. `8.7V / 2A` 是 OPPO 亮屏 VOOC 的常规输入档（约 18W），不是被模块压出来的；
3. `pb` 是**净入电池功率**，亮屏耗电会吃掉它，掉到 0.6W 时 `ibat=-136mA` 说明电池
   几乎不充、屏在吃电。真正能说明输入的是 `pin`，但这台机没有 `usb/current_now`，
   日志里只能打 `?`。

## 根因：cool_down 不该无条件写

`cool_down` 是 OPlus 的降流等级（`/sys/class/oplus_chg/battery/cool_down`）。之前的
逻辑只比"当前值 ≠ 目标值"就写，不看此刻电流是否正常。问题是**写入会让 OPlus 重新
选充电档**：

- PKB110：`ibat` 已经 4.3A（18W 里电池拿满），仍被写 `2 → 0`，三秒后掉到 9.7W；
- PKX110：写 `0 → 1` 后 `charge_technology` 7→14、3.6A→1.0A、32W→9W（v2.9.58 已记）。

同一节点、两个方向、两台机器，写之前都好好的，写之后都掉。说明掉档不是值的问题，
是**写入动作**触发重协商。2.9.64 之所以"正常"，是因为那时 `cool_down` 恰好已经是
目标值，没有触发写入。

## 修复

- 写 `cool_down=0` 前先读电池电流：**≥2.5A 视为未降流，直接不动**。只有确实被压到
  2.5A 以下，写 0 才是"解降流"，才值得冒重协商的风险；
- 写 0 的日志带上写入时的电流（`电流 XXXXmA`），以后一眼能看出这次写是不是多余；
- 补全输入电流读取：`charger/current_now`、`oplus_chg/charger/current_now`、
  `battery/input_current_now`。欧加把实测输入挂在 `oplus_chg/` 下，`power_supply`
  里没有 `usb/current_now`，所以以前一直打 `iusb=?A`、`pin=?W`。

## 影响

- 电流已经正常的机器：不再因为写 `cool_down` 自己把功率打下来；
- 真被降流的机器（亮屏游戏 5~10W 那类）：仍然写 0，逻辑不变；
- 有 `oplus_chg/charger/current_now` 的机器：日志能同时看到 `pin` 和 `pb`，区分
  输入功率与净入电池功率。

## 版本号

`3.0.6` / `versionCode 300013`。C 版 `3.0.6-c` / `300012`。

## 验证

- shell 仿真 663 项、C c-test 94 项全过；
- 新增断言：`ibat 4A` 时不写 `cool_down`、`ibat 1A` 时写 0。
