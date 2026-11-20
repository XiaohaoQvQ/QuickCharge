# Quick Charge v2.9.69（shell 版）

> 对应包：`QuickCharge-v2.9.69.zip` · `versioncode 29619`

模块描述直接带状态：管理器里点开模块，第一行就知道跑没跑、要不要重启。

## 一、描述三态

`description` 首段由脚本按实际情况写回，管理器列表和详情页都读这一行：

| 状态 | 描述 |
|---|---|
| 正常 | `✅ 运行中 · 温控档位 4/10（仅充电） · 配置 9 项` |
| 刚装完 / 刚更新 | `❌ 请重启 · 重启后开始工作` |
| 没运行 / 卡死 | `❌ 未运行 · 把 /data/adb/quickcharge/ 的日志发给作者` |

故障态不再拼档位摘要——配置都没生效，写出来只会误导；把日志路径放在描述里，用户不用再问「log 在哪」。

## 二、为什么用 emoji 而不是颜色

KernelSU 管理器（`ModuleMaterial.kt`）把 `description` 当纯文本喂给 `Text()`，不解析 HTML；写 `<font color="#3ddc84">` 只会原样显示成标签。所以只能靠 ✅ / ❌ 这些自带颜色的字符，Magisk、APatch 下也一样。

## 三、刚装完怎么认出来

「装好了没重启」在管理器上不是一次写盘：

1. 更新包先落在 `/data/adb/modules_update/quickcharge`，重启才搬进 `modules`；
2. 安装脚本写一个 `need_reboot`，开机由 `post-fs-data` 清掉；
3. `post-fs-data` 往数据目录写 `.boot_id`（这次开机的时刻）。

判定顺序：先看守护（在跑就是运行中）；没守护再依次看这三样，命中任一就是「待重启」；都不命中才是真故障。

`post-fs-data` 阶段**不刷描述**：那时守护还没起来，一刷就会把描述改成「未运行」，几秒后再被 `service.sh` 改回来，白白闪一下。现在由 `service.sh` 的 `sd_apply_state` 负责首刷。

描述也会在 `action.sh json` 时顺手校正一次——守护被外部杀掉后没人再写 `module.prop`，用户点开面板那次刷新就能把「未运行」落下去。

## 四、面板里那块还在

WebUI 顶部同样有一张三态牌，比描述多给 pid、心跳年龄和具体原因（例如「守护 pid=1234 已 320 秒没有心跳」）。描述一行放不下这些，两块互补。

## 验证

| 套件 | 结果 |
|---|---|
| `c-test` | 85 |
| `chg-unit` | 53 |
| `cool-unit` | 20 |
| `mount` / `zone` | 4 / 6 |
| `state-unit` | 12 |
| `sim` | 628（+3：安装后提示重启、未重启不写档位、运行中状态在前）|

`sim` 的描述断言全部改成「有守护才有摘要」的口径，并加了假守护现场（`/tmp/qcfake/service.sh`，`cmdline` 里带 `service.sh`，与 `sd_pid_is_daemon` 的判定路径一致）。踩到一个坑：`action.sh` 改完参数会 `sd_daemon_kick` 发 `USR1`，默认动作是终止进程，假守护第一脚就被踢死、后面全变「未运行」——现在脚本里 `trap "" USR1` 并循环 `sleep`。
