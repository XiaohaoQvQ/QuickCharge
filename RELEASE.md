# Quick Charge v3.1.12

验收报告剩下的两处「改了一半」，都是文本级：**preflight 的同步清单漏了它自己**，导致 C 仓的副本分叉了两版没人发现；`TECH.md`「已知限制」还把 `curr_max` 当现有开关写。**没有行为改动**，本轮只碰 `tests/preflight.sh` 与 `docs/TECH.md`，`lib/qc.sh`、`src/qcmon.c` 一行未动。

## 一、守卫自己不同步，等于 C 仓没有守卫

`tests/preflight.sh` 的 `same` 清单覆盖了 `src/qcmon.c`、`tests/c-test.sh`、`lib/qc.sh` 和四个脚本，**唯独没有它自己**。结果 3.1.11 主仓加了 versionCode 反算、去掉了重复检查，C 仓那份还停在旧版：

| 文件 | 行数 | 状态 |
|---|---|---|
| 主仓 `tests/preflight.sh` | 164 | 有反算、已去重 |
| C 仓 `tests/preflight.sh` | 148 | 无反算，仍留着重复的「电池偏热」检查 |

后果不是「少一条检查」这么轻：C 版的 `versionCode` 写错（手滑写成奇数、或按旧公式算成 `301121`）时，**没有任何检查会红** —— 而这正是 3.1.11 花整版去防的那类错。C 那份单独跑也不可用：它按主仓 README 的「当前版本」行取值，`A` 指向 C 仓时 9 项 FAIL。

改法就是把清单补齐，C 副本用主仓的覆盖：

```sh
same "$A/tests/preflight.sh" "$B/tests/preflight.sh" "tests/preflight.sh 逐字节一致"
```

**负向验证**：往 C 副本尾部追加一行 `# drift`，`FAIL tests/preflight.sh 逐字节一致`；还原后全绿。

## 二、`TECH.md` 的「已知限制」还在教人调 `curr_max`

「## 已知限制」里第一条是当前时态：

> **`curr_max` 只能限流，不能加速。** 充电功率由适配器、协议、电芯内阻决定，改上限无效。

`curr_max` 3.1.0 就删了，`customize.sh` 升级时还会把这个键从 `state.conf` 里清掉 —— 用户照着这条去调，调的是一个不存在的参数。同一节第二条已经改成「不设档位、不设温度墙、不设熔断」，这条是漏网。

保留结论、去掉开关：

> **任何电流上限都只能限流，不能加速。** 充电功率由适配器、协议、电芯内阻决定，改上限无效；**本模块不提供这个开关**。真正能提速的是让温度反馈变低（壳温伪装）。

## 测试

| 项 | 结果 |
|---|---|
| 语法 `sh -n` | 8/8 |
| `preflight.sh` | 全绿，0 bad（含新增的 preflight 自比对） |
| `preflight.sh --full` | 全绿 |
| 单元 | 92（state 12 / cool 28 / mount 4 / chg 44 / zone-rank 4） |
| 仿真 | 613/613 ×2 |
| c-test（x86 现编） | 93 |
| c-test（arm64 bin + qemu） | 93 |

`lib/qc.sh` 3969 行、`src/qcmon.c` 2676 行，均与 3.1.11 相同；`bin/qcmon` 重编只为内嵌版本串，`src/qcmon.c` 一个字节没改。

## 装机

覆盖安装，重启即可。

- 完整包：`QuickCharge-v3.1.12.zip`
- 更新清单：`update.json`

**C 版这版只有文档与测试脚本变动**，`bin/qcmon` 已重编、自报 3.1.12，行为与 3.1.11 完全一致。
