# Quick Charge v2.9.45（shell 版）

> 对应包：`QuickCharge-v2.9.45.zip` · `versioncode 29450`

这一版 shell 版**只改了一句文案**，守护逻辑、温度策略、参数默认值全部没有变动。

如果你现在用的是 2.9.44 shell 版，功能上没有任何差异，**可以跳过这次更新**。

## 改了什么

模块列表里的描述，在配置项数为 0 时原来显示：

```
QC · 温控档位 10/10 · 高刷关闭 · 未生效
```

改成：

```
QC · 温控档位 10/10 · 高刷关闭 · 配置未挂载
```

改动只有 `lib/qc.sh` 里 `sd_desc_text()` 的一行。

## 为什么要改

"未生效"这三个字有歧义：看到它，第一反应很容易是"模块没装好、没有工作"，
然后去反复重装——但实际模块一直在正常运行，只是这次没读到配置清单。

"配置未挂载"指向明确：**进程在跑，配置没挂上**。看到这句该去查清单文件，不是怀疑安装。

## 什么情况下会显示

配置项数来自"数清单行数"，两种挂载方式取的清单不同：

| 挂载方式 | 清单文件 | 计数方式 |
|---|---|---|
| 模块自己 bind 挂载 | `mounts.list` | 去重后计数 |
| 元模块（NoMount / Magic Mount / Mountify / Hybrid Mount） | `nm.list` | 按行数 |

shell 版两条分支都实现了，所以正常安装不会看到这句。出现"配置未挂载"通常是：

- 装了元模块，但元模块本身没激活（带 `disable` / `remove` 标记）
- 元模块激活了，但清单还没生成完（刚开机那一小段时间）
- 手动删过 `/data/adb/quickcharge/mounts.list` 和 `nm.list`

排查：

```sh
su -c 'wc -l /data/adb/quickcharge/mounts.list /data/adb/quickcharge/nm.list'
su -c 'sh /data/adb/modules/quickcharge/action.sh mount'
```

注意 `action.sh mount` 只重新挂载配置、重新生成清单，**不会立刻改描述**。描述由守护
定时同步：每 12 轮一次，默认 `tick=15`，也就是最多约 3 分钟。挂载完等一会儿再看描述：

```sh
# 当前描述
su -c 'grep description /data/adb/modules/quickcharge/module.prop'
# 清单实际行数
su -c 'wc -l /data/adb/quickcharge/mounts.list /data/adb/quickcharge/nm.list'
```

## 升级

直接覆盖安装，配置、日志、已调的参数全部保留。

- 2.9.44 → 2.9.45：`versioncode` 29440 → 29450，正常升级
- 2.9.43 → 2.9.45：同样是升级，跨版本没有格式变化

不需要清数据，不需要重启。描述由守护每 12 轮同步一次，默认 `tick=15`，
约 3 分钟内会自动更新。

## 文件

| 项 | 值 |
|---|---|
| 大小 | 67,391 字节 |
| 文件数 | 17 |
| 最低要求 | Magisk / KernelSU / APatch 任一 |
| 架构 | 全架构（纯 shell，无二进制） |

## 校验值

```
b7e73a23aedf76a643527fc42179200dac4f2e04fe8567809d90f6a70bbdbd13  QuickCharge-v2.9.45.zip
```

```sh
sha256sum QuickCharge-v2.9.45.zip
```

这个包的构建是可复现的：同一份源码、同一套打包脚本，任何时候重打都得到相同的字节和相同的
sha256（`pack.sh` 里统一了 zip 内时间戳并去掉了高精度时间字段）。

## 另一个版本

同版本另有 C 守护版 `QuickCharge-v2.9.45-c.zip`（`bin/qcmon`，热路径零 fork）。
两版功能等价、可随时互换，详见 [QuickCharge-C](https://github.com/XiaohaoQvQ/QuickCharge-C) 的 README 与 Release。
