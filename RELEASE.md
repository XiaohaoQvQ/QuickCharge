# Quick Charge v3.1.0

这一版是减法：**把所有安全保护删掉，只留充电速度**，顺带修掉 3.0.12 审计里的两个
P1，并清掉一批死代码。行为变化很大，升级前请读完第一节。

## 一、安全保护整套删除（破坏性）

| 删掉的东西 | 原来的行为 |
|---|---|
| 熔断守卫 | 电池 48℃ / 主板 85℃ 撤销全部伪装并暂停，回落 3℃ 自动恢复 |
| 温度墙 | 真实温度到墙就交还系统 |
| 温差档位 `aggr` | 0 到 10 档，拉开上报值与真实值的差距 |
| 绝对电流墙 `curr_max` | 按温度把电流压到 100 / 75 / 50 / 25% |
| 电量阈值 `fast_cap` | 电量超过 55% 停止伪装、交还壳温 |
| 阶梯解锁 45℃ 撤销 | 电池到 45℃ 自动还原 HAL 限流节点 |
| 电池伪装 46℃ 撤销 | 真实温度到 46℃ 自动关掉 NTC 伪装并冷却 120s |

现在伪装值是**恒定**的：不看真实读数、不设温度墙、不设熔断线、不按电量退出，
插着电就一直让系统以为电池很凉。`shell_temp` 默认 25℃，范围收紧到 20 到 33℃，
下限是硬性的——再低不少平台把 NTC 判成开路，反而锁 5V/500mA。

**热失控的最后一道防线只剩系统和电芯自己的保护板。** 充电时请自己摸一下机身温度，
发烫就拔线，或者 `action.sh temp off` 停掉伪装。

## 二、修掉两个 P1

**`sd_chg_current_v` 回退路径没做单位归一。** 有的机型 `current_now` 报 mA，
有的报 µA。回退分支直接拿原始值去和 2.5A 比，报 mA 的机型在 4A 正常充电时
会被当成「已降流」，于是去写 `cool_down` 的 0——而写入本身会让 OPlus 重选档。
现在补了 `sd_uv_norm`，判据与主路径一致：`0 < |v| < 20000` 一定是 mA。

**C 版 `cool_tick` 完全没有电流闸。** shell 侧 3.0.6 就加了「只在真被降流时写 0」，
C 版一直是裸写，两台机器同一个配置能跑出两种结果。现在两边对齐，并且 C 侧的
`chg_current()` 也做了同样的单位归一（报 mA 的机型 `3000` 不会被当成 3mA）。

## 三、清掉的死代码

- shell：`sd_sentinel_guard`、`sd_guard_one`、`sd_guard_cooled`、`sd_zone_is_guard_src`、
  `sd_limit_for_type_v`、`sd_curr_target_v`、`sd_curr_target`、`sd_curr_keep`、
  `sd_curr_apply`，以及 `_st_aggr` / `_st_wall` / `_st_fast_cap` 等 11 个配置键。
  `lib/qc.sh` 从 4377 行降到 3921 行。
- C：`curr_target`、`curr_keep`、`is_guard_src`、`guard_one`、`guard_cooled`、
  `sentinel_guard`、`limit_for_type`、`wall_of`、`batt_capacity`、`batt_max`、
  `curr_is_ua`、`curr_read`、`now_sec` 等 14 个函数和 8 个配置字段，
  `src/qcmon.c` 从 2969 行降到 2659 行，`-Wall -Wextra` 零告警。
- 命令行删掉 `wall` / `curr` / `curredge` / `boost` / `fast` / `sentinel` / `battery` /
  `gear`|`aggr` 八个子命令（`temp` / `shell` / `base` / `batt` / `unlock` 仍在）。
- 面板：五张限速滑块压成一个「伪装温度」，摘要从 `温控档位 8/10` 改成 `温度伪装 25℃`。

## 四、顺带修的几处

- `sd_telemetry_sample()`：极速模式不再读真实温度，`run/sensor` 里的真实值就空了，
  面板「真实」一栏会一直是 —。补了一个纯遥测采样，真实温度仍然只用于显示，不参与判断。
- C 版 `scr_apply()` 修掉变量遮蔽，并复用已读的节点原文，不再重复 `read_line`；
  `screen_sample()` 内层循环变量改名，不再遮蔽外层 `i`。
- 升级迁移（`defrev=4`）：清掉八个废弃键，`shell_temp` 超过 33℃ 的收到 25℃。

## 版本号

`3.1.0` / `versionCode 301001`，C 版 `3.1.0-c` / `versionCode 301000`。
按「删功能 / 改语义 → 次版本 +1」的规则，这是 3.0 之后第一个次版本。

## 验证

- shell 仿真 588 项全过，用时 75 秒（3.0.12 是 89 秒）。新增的用例覆盖恒定上报、
  20/33℃ 边界、越界夹取、电量 80% 仍继续伪装、电池 49℃ 仍继续伪装、
  升级时八个旧键被清空。
- `chg` / `cool` / `state` / `mount` 单元测试共 87 项全过。`cool-unit` 新增电流闸
  六条（4.3A 不动、1.5A 写 0、负值按绝对值、2.5A 边界含在闸内）。
- C 仓 `tests/c-test.sh` 81 项全过，含新增的「报 mA 的机型 3A 同样不动」。
- 仿真套件现在每次从仓库本体刷新 `/mod`，不再靠手工同步——之前忘了同步就整套跑旧代码，
  断言全绿也不作数。
