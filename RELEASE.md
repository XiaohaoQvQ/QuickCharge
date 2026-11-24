# Quick Charge v3.0.3

修一个升级通道的配置错误：**装到最新版之后，模块卡片上的「更新」按钮还在，点开显示的就是当前
版本**。充放电逻辑没有任何改动。

## 原因

`module.prop` 里的版本号字段写成了全小写的 `versioncode`，而 Magisk / KernelSU 的管理器
按驼峰 `versionCode` 取值。键名对不上时不会报错，本地版本号被读成 `0`：

```
远端 update.json  versionCode = 300005
本地 module.prop  versionCode = 0        ← 键名不匹配
300005 > 0  →  永远判定「有新版本」
```

KernelSU 的 `list` 命令把 `module.prop` 的键原样输出，管理器再按 `versionCode` 取整数值，
中间没有任何大小写归一化，所以这个错误会一路传到 UI。

其他模块不出现这个问题，是因为它们的 `module.prop` 一直写的是规范的 `versionCode`。

## 修复

两仓的 `module.prop` 改为 `versionCode=`（驼峰），并同步 `update.json`。同时把模块内读取
自身版本的代码改成两个键名都试一次，升级过程中不会因为读空值把指纹打成 0。

## 这一版需要手动刷一次

你现在设备上的 3.0.2 本地版本号被读成 `0`，任何大于 0 的远端版本都会提示更新。刷入 3.0.3
之后本地能正确读出 `300007`，与 `update.json` 相等，按钮就不再常驻了。

也可以直接点卡片上的「更新」按钮装这一版——它下载的就是 3.0.3，装完同样会恢复正常。

## 更新通道改用 Releases 直链

`module.prop` 的 `updateJson` 从 jsDelivr 换成了：

```properties
updateJson=https://github.com/XiaohaoQvQ/QuickCharge/releases/latest/download/update.json
```

jsDelivr 的 `@main` 分支缓存 12 小时、不能 purge，发版后一整天收不到提示，这次踩到了。
`latest/download/` 是 GitHub 自己的重定向，每次实时解析到最新一版，没有缓存层。

代价是每次发版要**把 `update.json` 和 `RELEASE.md` 一起作为 Release 资产上传**，漏传就会 404。

## 版本号

`3.0.3` / `versionCode 300007`。C 版同步发布 `3.0.3-c` / `300006`，各仓 Release 只附自己
那一份模块包。

## 验证

- shell 仿真 657 项、机型矩阵 69 项、C c-test 90 项全过；
- `chg` 44、`cool` 20、`state` 12、`mount` 4、`zone-rank` 6 全过；
- 包内 `module.prop` 的 `versionCode` 与 `update.json` 逐字核对一致。
