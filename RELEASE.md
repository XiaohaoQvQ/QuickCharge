# Quick Charge v2.9.59（shell 版）

> 对应包：`QuickCharge-v2.9.59.zip` · `versioncode 29591`

这一版没有功能改动，只修一份真机日志暴露出来的三处读数问题。
它们不影响充电本身，但会让日志和面板说假话。

## 一、`vbat=0.004V`：单位没归一

日志里电池电压整段是 `0.004`，电量却在 71% 正常爬升。

`power_supply/battery/voltage_now` 这个节点各机型不统一：多数报 µV
（`4219000` = 4.219V），也有报 mV 的（`4000` = 4.0V）。代码一律按 µV 换算，
于是 4.0V 被算成 0.004V。

连带的后果比显示错更麻烦——判重签名里的功率是这么算的：

```sh
pwk=$(( ibm * vbat / 1000000000 ))
```

`vbat` 小 1000 倍，`pw` 恒等于 0，2.9.57 的「按 1W 分档判重」在这类机器上
直接失效，日志又退回靠 `usb=8.55→8.96` 这种 0.01V 抖动触发，3 秒一条。

**改法**：读出来先归一，再格式化。

```sh
sd_uv_norm() {
    if [ "$v" -gt 0 ] && [ "$v" -lt 20000 ]; then
        t=$((v * 1000))
        [ "$t" -ge 100000 ] && [ "$t" -le 30000000 ] && _sd_rv=$t
    fi
}
```

`vusb`、`imax` 一起走这个函数。阈值取 20000 是为了不误伤空载的 `30000`
（0.03V），再用结果区间做二次校验，`0.03V` 不会被乘成 30V。

## 二、日志时间比本地早 8 小时

同一份日志里两种时间：

```
11-19 09:52:27 | boot        ← 脚本，本地时间
11-19 01:53:18 qcmon 启动     ← qcmon，UTC
```

qcmon 是静态二进制，拿不到 Android 的时区库（设备上没有
`/usr/share/zoneinfo`），`localtime_r()` 直接落到 UTC。

**改法**：启动时问一次 `date +%z`，把 `+0800` 拼成 POSIX 的 `XXX-8`，
`setenv("TZ")` 之后 `tzset()`。这种写法不需要 tzdata 文件。

## 三、屏幕判不出来

`屏幕 无亮度节点，按亮屏处理` —— `g_bl` 固定 `/sys/class/backlight`、
`g_fb` 固定 `/sys/graphics/fb0/blank`，这台两处都为空，屏幕状态于是恒为亮屏。

后果是「亮屏快充」永远停在「还没有基准值」，熄屏 30 秒延迟释放也不会触发。

**改法**：`backlight` 目录扫不到时再试几个常见落点 ——
`/sys/class/leds/lcd-backlight/actual_brightness`、
`/sys/class/leds/lcd-backlight/brightness`、`/sys/class/leds/lcd/brightness`、
`/sys/class/backlight/panel0-backlight/brightness`；`fb0/blank` 也补上
`/sys/class/graphics`、`/sys/devices/virtual/graphics` 两条路径。

## 四、测试

| 套件 | 结果 |
|---|---|
| `c-test` | 69 通过（新增「vbat 报 mV 时归一」） |
| `chg-unit` | 33 通过 |
| `cool-unit` | 16 通过 |
| `mount-unit` | 4 通过 |
| `zone-rank` | 6 通过 |
| `sim` | 621 通过 |

## 五、文件

| 项 | 值 |
|---|---|
| 最低要求 | Magisk / KernelSU / APatch 任一 |
| 架构 | 全架构（纯 shell，无二进制） |

同版本 C 守护版见 [QuickCharge-C](https://github.com/XiaohaoQvQ/QuickCharge-C)。
