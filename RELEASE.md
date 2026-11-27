# Quick Charge v3.1.14

这一版没有改任何充电策略。改的是**日志能不能回答问题**，以及**两个守护同时在跑**这件事。

起因是一份 PLG110 的「10–20W」日志：`log_level=1`，全日志 `[chg]` **0 条**——用户说功率低，
日志里连「在不在充、充多少」都没有。同时日志里出现了两套格式的「熄屏/亮屏」，间隔 1–3 秒，
说明 C 版 qcmon 和 shell 守护在同时写同一份 `log.txt`。

## 日志：1 级也要有功率

`sd_chg_snapshot` 的门禁从 2 级降到 1 级，2 级仍记 `S`（现场），1 级降级成 `I`。签名去重与
10 分钟节流没动，所以一次充电大约 1 条「插电」+ 每 10 分钟 1 条 + 1 条「停充」。

```
I [chg] 插电 vusb=8.85V iusb=?A imax=2.00A vbat=4.219V ibat=4000mA pin=?W pb=16.9W 60% 38℃ cool=? vooc=? tech=? type=USB_DCP rtype=? scr=1 cells=1 status=Charging
```

用户默认就是 1 级，所以这不是「给某个人修」，是**每一份功率反馈都缺同一块证据**。

## 双守护：三处一起收

- `qcmon` 自己校验 `module.prop` 的 `channel`，不是 `c` 就写一条 `E` 并退出。以前守卫只在
  `service.sh` 里，谁把二进制拉起来它就跑。
- `service.sh` 在非 C 通道（或 `SD_SHELL_DAEMON=1`）时，把 `/proc` 里 cmdline 含 `bin/qcmon`
  的进程收掉，并记一条 `W`。
- `customize.sh` 装完检查通道，不是 `c` 就删掉 `$MODPATH/bin`——从 C 版刷回 shell 版时，
  Magisk 只覆盖同名文件，旧包的 `bin/qcmon` 会留在模块目录里等着被拉起来。

危害不是多几行日志：两个守护共用 `run/` 下的 `scr.orig`、`fcc.norm`、`unlock.orig`，会互相
覆盖备份；而 ≤3.1.12 的 qcmon 还会写 `cool_down`，能把 VOOC 直接打到 2W 档。

## 一个变量两个主人

`service.sh` 把 `_sd_scr_log` 当「只记一次」的开关（置 1），`sd_scr_tick` 把它当「上次记过的
状态」（用 `""`/`wait`/`fcc`）。于是每轮互相踩：service 看到 `fail≠1` 记一条并改成 1，
`sd_scr_tick` 看到 `1≠fail` 又记一条并改回 `fail`。一份日志里「屏幕 判定」77 条、
「亮屏快充：本机不支持」78 条，就是这么来的。

现在 service 侧改名 `_sd_scr_once`；「本机不支持」改成**状态变化记一条 + 每 30 分钟兜底一条**；
`Full` 从 `Charging` 里分出来，满电不再刷这条 W（它本来也不是「亮屏降流」的证据）。

## env 行的两个数

`charge-nodes=1/0` 里的第二位数一直是 0。表面看是 `cn`/`ce` 两行写反，真正的根因是
`sd_curr_nodes` 跑在 `$(...)` **子 shell** 里——它内部填的候选表出了子 shell 就没了，
所以只调顺序没用，必须先在当前进程 `_sd_curr_prepare`。

顺带把「命中的到底是哪几个节点」打进日志（全路径，`battery/current_max` 与
`usb/current_max` 分得开），以及 `cool_down` 的值与可读性——只给数量时，
`fcc 节点=none` 是一句没法追查的结论。

## 其他

- 启动日志记 `service.sh`/`lib/qc.sh` 的 `md5@mtime`。这次的「包是对的、跑的不是包里那份」
  只能靠 3 秒节拍反推出来，以后一眼可查。
- `cool_down` 节点存在但读不到时记一条一次性 `W`，不再静默。
- 「N 条未卸净」带上具体路径。
- WebUI 与 TECH 未改（本版没有行为变化）。

## 升级提示

**这一版仍然没有回答「PLG110 为什么只有 10–20W」**，因为那份日志缺的就是功率。装完
3.1.14 后按下面三步取一次数，一条就能定性：

```sh
su -c 'sh /data/adb/modules/quickcharge/action.sh level 1'   # 默认就是 1 级，够用
# 拔线 → 插线 → 亮屏放 60s → 息屏放 60s → 导出 log.txt
su -c 'sh /data/adb/modules/quickcharge/action.sh tiers'
```

判读：`pin` 掉、`pb` 不掉 → 线/头/协议；`pb` 掉、`cool` 被抬起 → 亮屏降流；`pb` 掉、`bt` 高 →
温度墙；`pb` 掉、`cool=0`、`bt` 不高、`tiers` 里有非 0 的 `thermal_charging` → HAL 在压。

## 测试

- 单元 95（chg-unit 45 / cool-unit 30 / state-unit 12 / mount-unit 4 / zone-rank 4）
- 仿真 629（连跑两遍全绿）
- c-test 100（x86 现编 + arm64 包内二进制 + qemu 双跑）
- `preflight --full` 全绿，含两仓逐字节比对与 `3.1.14 → 3011401` 反算
