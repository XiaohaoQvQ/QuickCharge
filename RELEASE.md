# Quick Charge v2.9.71（shell 版）

> 对应包：`QuickCharge-v2.9.71.zip` · `versioncode 29623`

修面板版本号显示成 `vBinary file /data/adb/modules/quickcharge/module.prop matches` 的问题，并让 module.prop 以后不再被写坏。

## 一、那句话是怎么来的

`module.prop` 被编辑器按 UTF-16 存过一次后，每个字符后面都跟一个 NUL 字节。整份文件在 `grep` 眼里就是二进制，于是它不再输出内容，而是输出一句：

```
Binary file /data/adb/modules/quickcharge/module.prop matches
```

面板取版本用的是 `grep '^version=' … | cut -d= -f2`，拿到的就是这句话；前端再拼一个 `v`，就成了 `vBinary file /data/adb/modules/quickcharge/module.prop matches`。文件本身没坏，管理器里模块名、作者都还在，只是所有 `grep` 读出来的字段都变成了这句提示。

常见触发：用 MT 管理器 / VS Code 编辑 `module.prop` 后另存为「UTF-16」或「UTF-16 LE」；也有编辑器会在文件头写 BOM 后整份转码。

## 二、读取统一走 sd_prop_get

新增两个函数：

- `sd_prop_has_nul`：比较 `tr -d '\000'` 前后的字节数，判断文件里有没有 NUL。
- `sd_prop_fix`：有 NUL 就按 `UTF-16` / `UTF-16LE` / `UTF-16BE` 依次试 `iconv`，转出来的结果必须无 NUL、无 U+FFFD（否则说明端序猜错，中文会变问号）；`iconv` 缺失或全失败时退化成删 NUL。原文件先备份成 `module.prop.utf16.bak` 再原子替换。
- `sd_prop_get <key> [file]`：先修再 `grep -a`，即使修复失败也不会把「Binary file」混进值里。

所有读点都换成了它：面板 `json` 的 `version`、启动日志的 `module=`、`action.sh check` 的版本行、`sd_fingerprint` 的 `versioncode`、安装脚本的标题与冲突提示。

## 三、自愈时机

`sd_sync_desc` 开头先 `sd_prop_fix`。守护启动、`action.sh json`、描述同步都会经过这里，所以升级后第一次开机就会把坏文件转回 UTF-8，不用手动改。修复只发生在检测到 NUL 时，正常 UTF-8 文件只读不写（`sim` 里对 md5 做了断言）。

## 验证

| 套件 | 结果 |
|---|---|
| `c-test` | 85 |
| `chg-unit` | 53 |
| `cool-unit` | 20 |
| `mount` / `zone` | 4 / 6 |
| `state-unit` | 12 |
| `sim` | 639（+8：UTF-16 读版本、不吐 Binary file、转回 UTF-8、中文一致、留备份、正常文件不动）|

`sim` 的 T49 用 `iconv -f UTF-8 -t UTF-16LE` 现场造一个坏文件，再跑 `sd_prop_get` 验证：版本号能读出来、没有 `Binary file` 字样、文件转回 UTF-8、描述与原文逐字相同、备份存在。
