# Quick Charge v3.1.15

这一版只改一件事：**让你确定自己跑的是装上的那份代码**。

3.1.14 的验收报告里带了一份 PLG110 现场日志：装的 3.1.14，跑的是 3.1.11。旧守护在文件被
覆盖后一直没退，boot 段看到它活着就跳过，于是 3.1.13 的「cool_down 只读」「去掉 3 秒热循环」
和 3.1.14 的「1 级日志有功率」在这台机器上**一条都没生效**——用户对着旧行为报了半个月的
「功率上不去」，我们却在新的代码里找原因。

## 旧守护让位

`sd_pid_is_daemon` 只判断「cmdline 里有 `service.sh`」，判断不了「是不是这一份」。现在：

- 守护启动时把 `service.sh` / `lib/qc.sh`（C 版还有 `bin/qcmon`）的 `md5@mtime` 写进
  `run/daemon.ver`，**先写指纹再写 pid**，看到 pid 就一定知道它对应哪份代码；
- `service.sh` 的 boot 段在「守护已在运行，跳过」之前比一次：不一致就 TERM 旧进程、清锁、
  重新拉起，日志里留一条
  `W [daemon] 守护(pid=…)跑的不是磁盘上这份代码：<旧> → <新>，收掉重起`；
- 没有 `daemon.ver` 的守护就是 3.1.14 或更早起的，按旧代码处理；
- `action.sh` 的 start/restart 走同一个判断，不必等开机。

这条校验的位置也是内容：放在「守护已在运行，跳过」之后等于没写，`preflight` 现在按行号
断言它在前面（`第 N 行 < 第 M 行`）。

## 指纹挪到 env

原来只有 `sd_daemon()` 打指纹，而「跳过」分支根本进不到那里——用来抓「跑的不是包里那份」
的手段，被放在了「跑的那份」里面。现在 `sd_dump_env` 每次都会打：

```
I [env] 代码指纹 service.sh=70d5afc8@11-27 21:17 lib/qc.sh=58b75e28@11-27 21:17
```

boot 段、`action.sh env`、打开日志时都会走它，跳过守护也看得到。

## 平台认对后候选表重算

`_sd_curr_prepare` 只填一次表，而 `sd_plat_resolve` 专门设计了「`other` 不缓存、最多试 8 次」
等 `getprop` 就绪。两者叠在一起就成了空转：第一次填表时平台若还是 `other`，MTK 那 5 个候选
（`input_current_limit`、`charger/current_max`、`mtk-master/slave-charger`、`mtk-battery`）
**永久拿不到**，之后认对也不补，日志看起来只是「本机不支持」。

现在建表时记住 `_sd_curr_plat`，平台从 `other` 认对就清表重填；`SD_CURR_NODES` 覆盖的表不动。
C 侧 `curr_prepare` 同样处理（`g_curr_plat`）。

顺带对齐两侧的候选表：C 侧原来只有 8 个候选、`MAXCURR` 还是 12，MTK 机型会被静默截掉
`mtk-battery`，两份日志的 `x/y` 永远对不上。现在两侧都是 15 个（基础 10 + MTK 5），
重探周期也统一成每 4 轮（原来 shell 4 轮、C 20 轮，tick=15s 时是 1 分钟和 5 分钟）。

## 零碎

- `sd_dump_env` 里调一个 3.1.0 就删掉的函数（`sd_limit_for_type_v`），每次 dump 一条
  `command not found` 到 stderr。删掉调用与 `local slim`。杂音久了会把「stderr 有东西」
  当成正常。
- `qcmon.c` 里讲「2.5A 闸」「去写 0」的注释——那个闸从 3.1.13 起就不存在了，改成讲
  `ua_norm` 真正的作用（不归一的话 4A 会被算成 3mA，功率与判重全错）。
- `customize.sh` 删 `bin/` 前加 `[ -f module.prop ]` 前置：C 包若缺 `module.prop`
  （Magisk 会拒装，第三方管理器不一定），空 ≠ `c` 会把 C 包自己的二进制删掉。
- `RELEASE.md` 里「三处一起收」的措辞降一档：标准安装流程解压到 `modules_update/<id>`
  （新目录，本来就没 `bin`），`customize.sh` 那条是兜底；真正拦住旧 qcmon 的是
  `service.sh` 的运行时清理和 qcmon 自己的通道闸。

## 自查（升级后建议跑一次）

```sh
su -c 'echo "守护启动: $(stat -c %y /proc/$(cat /data/adb/quickcharge/run/daemon.pid))"; echo "脚本更新: $(stat -c %y /data/adb/modules/quickcharge/service.sh)"'
```

守护启动时间早于脚本更新时间，就是在跑旧代码。装完 3.1.15 之后这条应当自己消失；
如果还在，日志里会有那条 `W 跑的不是磁盘上这份代码`，把日志发过来就行。

## 测试

- 单元 95（chg-unit 45 / cool-unit 30 / state-unit 12 / mount-unit 4 / zone-rank 4）
- 仿真 641（连跑两遍全绿；新增 T54 收掉并存的 qcmon、T55 旧守护让位、T56 平台重算）
- c-test 102（x86 现编 + arm64 包内二进制 + qemu 双跑；新增 [21] MTK 候选表 15 个）
- `preflight --full` 全绿，含两仓逐字节比对（这次把 `tests/sim/run.sh` 也加进了清单）、
  `3.1.15 → 3011501` 反算、以及 7 条新守卫

顺带修掉一个用例自身的竞态：`tick=60 插电仍伪装` 靠「读 pid 文件再 kill」停守护，而
`emul_temp` 是 `sd_apply_state` 写的、写在启动守护之前，抢在中间时 pid 文件还不存在，
kill 落空 → 旧守护活着 → 下一个 `--daemon` 直接「已有守护在运行」退出。改走
`sd_daemon_stop`（按「谁是守护」找进程并清锁）。这条在 3.1.14 上是偶发红，不是本版引入。
