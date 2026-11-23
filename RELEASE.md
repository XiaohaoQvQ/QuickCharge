# Quick Charge v2.9.74（shell 版）

> 对应包：`QuickCharge-v2.9.74.zip` · `versioncode 29629`

核心参数卡底部加了一个「极限充电」按钮：一次把息屏满速、温度墙顶到熔断前 1℃、
停系统热管理全部打开，再点一次恢复原设置。

## 一、按钮做什么

| 项 | 值 |
|---|---|
| 温度墙 | 电池熔断阈值 − 1℃（默认 47℃），不再受滑块 42℃ 限制 |
| 限流提前量 | 0，到墙才降档 |
| 温控档位 | 10 |
| 快充阈值 | 85% |
| 温度模式 | 仅充电 |
| 系统热管理 | 停 horae |
| 息屏 | 不 +2℃、不压回 `lim-3`，与亮屏同目标 |

熔断不动：真实温度到 `battery_limit` 照样撤伪装。开启前的 `wall` / `curr_edge` /
`aggr` / `fast_cap` / `temp_mode` / `horae` 写进 `run/max.bak`，关闭时原样恢复。

## 二、实现

- 新增 `max_mode` 状态位，只改两处：`sd_curr_target_v` 的墙与息屏分支、`sd_shell_target` 的屏障。
- `action.sh max on|off` 做批量设置与快照恢复；面板按钮走同一条命令（带确认弹窗）。
- `action.sh json` 增加 `"max":true|false`，按钮状态随面板刷新同步。
- C 守护同步解析 `max_mode`，`curr_target` / `shell_target` 与 shell 版一致。

## 三、验证

| 套件 | 结果 |
|---|---|
| `sim` | 659（+13：max 开 / 关 / 息屏墙 / json）|
| `c-test` | 86（+2：[6c] 极限墙 42→47、关闭回 42）|
| `chg-unit` / `cool-unit` | 44 / 20 |
| `state-unit` / `mount` / `zone-rank` | 12 / 4 / 6 |

面板截图核对：按钮高亮显示「极限充电 · 已开启」，标题行同步 `档位 10 · 墙 47℃`。

## 四、边界

墙只决定「什么时候开始降」，不改变电池本身的接受能力。电量 80% 以上进入恒压、
非原装头线只给 9V/1A，这两种情况按钮也拉不回来。
