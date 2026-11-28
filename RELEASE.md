# Quick Charge v3.1.18

> 从 3.1.16 或更早升上来的，3.1.17 和 3.1.18 的内容都在这一版里。3.1.17 发出去十分钟后
> 发现 C 侧的 `env` 字段没跟上说明，单独补了一版 —— 版本号不跳，用户就不会装到「说明写了、
> 代码没做」的那一版。

## 安全模式不再被兜底推翻

`post-fs-data.sh` 连续多次开机未完成时会写 `step=safe-mode` 然后跳过挂载。3.1.16 的
`service.sh` 只认 `done`，其余 step 一律算「没跑完」，于是它起来第一件事就是把安全模式
刚跳过的覆盖层重建、再挂回去 —— 安全模式的结论只在 `service.sh` 也起不来时才成立，
而那种时候又没人需要它。

现在 `safe-mode` 单独识别为主动跳过：

- 打一条 `W [boot] post-fs-data 按安全模式跳过挂载（连续开机未完成），本次不重建`；
- 不重建、不补挂，覆盖层维持上次状态；
- 计数仍由 `service.sh` 在 `boot_completed` 之后清零，只要它起得来，下一轮就回到正常流程。

「停在中途」和「主动跳过」是两件事，不该共用一条兜底。

## 清理残留锁终于进日志

`post-fs-data.sh` 里这段代码写了两遍：第一遍把结果 `echo` 到 stderr，第二遍才 `sd_info`。
第一遍已经把 `daemon.lock` 删了，第二遍的 `if` 条件永远不成立 —— 所以「清理上一轮残留的
守护锁」这句话在模块日志里从来没出现过。

更靠里的原因：`sd_info` 受 `_sd_lv` 控制，而 `_sd_lv` 要等 `sd_state_load` 之后才是 1，
这段代码偏偏写在 `sd_state_load` 之前，等于无论写几遍都是 0 级，一条都落不了盘。

现在合并成一条并挪到 `sd_state_load` 之后。

## C 侧 `env` 补齐 `nm=` 字段

3.1.16 的说明里写了 `[env]` 新增 `overrides=N mounts=N nm=bind|nomount alive=yes|no`，
但 C 侧只落了前两个：`nm=` 一直没打，而且元模块（NoMount / Magic Mount / Mountify）激活时
没有 bind mount，`mounts=0` 直接把 `alive` 推成 `no` —— 明明注入成功了，日志却说没生效，
正是这套字段要防的那种误导。

现在 C 侧与 shell 对齐：元模块激活时打 `nm=nomount`，存活按 `nm.list` 非空且
`$MODDIR/system` 存在判定。两个通道的 `[env]` 行可以直接对照着看。

## 「改写无差异」不再一律说成格式不匹配

`3.1.16` 加了「改写产物与原件逐字节相同就告警」。但告警原文写的是「格式或目标值不匹配」，
把「这份配置本来就是这个值」也归成了故障 —— 后者是正常状态，只是不需要写覆盖层。
现在措辞把两种可能并列写清楚，汇总行的「无差异 N」照旧。

## 测试

- `tests/sim/run.sh` 新增 T58 九条断言：`phase=done` 不报错、`phase=build` 告警并真的
  重建出文件、`phase=safe-mode` 不重建、残留锁清理进日志。用例数 643 → 652；
- `tests/c-test.sh` 新增三条：`nm=bind` 出现在 `env`、元模块激活时 `nm=nomount`、
  `nm.list` 非空时不误报 `alive=no`。用例数 102 → 105；
- `tests/preflight.sh` 加两条守卫：「`service.sh` 认 `safe-mode`」「清理锁必须写在
  `sd_state_load` 之后」，防止这两个坑被改回去。

## 升级说明

覆盖安装即可，`state.conf` 与 `daemon.ver` 的格式没变。装完看日志第一段：

```
I [boot] 清理上一轮残留的守护锁(旧 pid=xxxx)   ← 有残留锁时才会出现，现在能看到
I [env] overrides=8 mounts=8 nm=bind alive=yes
```

如果 `alive=no` 而 `mounts` 也是 0，说明覆盖层没挂上，把这一段连同
`su -c 'cat /proc/self/mountinfo | grep files'` 的输出发回来。
