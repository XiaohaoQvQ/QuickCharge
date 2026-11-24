# Quick Charge v3.0.2

接入模块在线升级。刷完这一版，之后在 KernelSU / APatch / Magisk 的模块列表里就能直接看到
「更新」按钮，点一下自动下载安装，不用再手动找包。

充放电逻辑与 3.0.1 完全一致，本版只加了升级通道，没有行为改动。

## 在线升级怎么工作

`module.prop` 多了一行 `updateJson`，指向仓库根目录的 `update.json`：

```properties
updateJson=https://cdn.jsdelivr.net/gh/XiaohaoQvQ/QuickCharge@main/update.json
```

管理器定期拉这个 JSON，把里面的 `versionCode` 和本地 `versioncode` 比大小，远端更大就在
模块卡片上显示更新提示。点更新时下载 `zipUrl`，走的是和手动刷入完全一样的安装流程。

| 字段 | 作用 |
|---|---|
| `version` | 卡片上显示的版本名，纯展示 |
| `versionCode` | 唯一参与比较的整数，必须严格递增 |
| `zipUrl` | 点击更新后下载的直链，指向本仓 Release 资产 |
| `changelog` | 更新说明的地址，管理器拉下来渲染在弹窗里 |

`updateJson` 和 `changelog` 都走 jsDelivr，`raw.githubusercontent.com` 在国内经常超时。

## 这一版仍需手动刷一次

旧版本（3.0.1 及更早）的 `module.prop` 里没有 `updateJson` 这一行，管理器根本不会去查远端，
所以它们收不到任何提示。手动刷入 3.0.2 之后，升级通道才算打通，3.0.3 起就能点按钮了。

## 版本号

`3.0.2` / `versioncode 300005`。C 版同步发布 `3.0.2-c` / `300004`，两仓模块包分开下载，
各仓 Release 只附自己那一份。

## 验证

shell 仿真 657 项、机型矩阵 69 项、C c-test 90 项全过；`chg` 44、`cool` 20、`state` 12 全过。
`update.json` 的 `versionCode` 与 `module.prop` 逐字核对一致。
