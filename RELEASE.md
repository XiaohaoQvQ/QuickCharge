# Quick Charge v3.0.12

修两个让温控表「写了但没生效」的兼容问题，不改温控与充电的判断逻辑。
升级后建议重启一次，让配置层重新生成并挂载。

## 一、带 BOM 的温控表被整份丢弃

部分 ROM 的 `sys_thermal_control_config.xml` 以 UTF-8 BOM 开头（`EF BB BF`）。
校验函数只看第一个字节是不是 `<`，取到 `0xEF` 就判定「非 XML」，
整份文件不生成，日志里表现为：

```
校验失败(非 XML): .../sys_thermal_control_config_xxx.xml
```

结果是这台机器的温控开关从未被改写，充电限流自然也没解开。
现在跳过 BOM 再判首字符，原件与产物都不改动，仍保留原有的一致性校验
（配平 + 标签数）。

## 二、chcon 全数失败

覆盖文件的 SELinux 上下文原来靠 `chcon --reference=原件` 继承，
这是 GNU 扩展，Android 的 toybox 版 `chcon` 不认，实测每台机都是全数失败：

```
3/3 个文件 chcon 失败（清单: .../run/chcon.fail）
```

上下文没设对，`thermalservice` 可能读不到覆盖文件，等于白挂。
现在改成三级：先试 `--reference`，失败则用 `ls -Z` 读出原件的
`u:object_r:xxx:sN` 再显式设置，仍失败才计入失败清单。
`chmod` / `chown` 的 `--reference` 是同一个来源的 GNU 扩展，一并加了显式兜底。

另新增 `SD_CTX_OVERRIDE`，少数 `ls` 不带 `-Z` 的老 ROM 可手动指定上下文。

## 版本号

`3.0.12` / `versionCode 300025`。

## 验证

- shell 仿真 683 项全过。其中温控表样本已改为 BOM 开头，用于覆盖第一条；
  仿真里的 `chcon` 桩改成「拒绝 `--reference`、只认显式上下文」，与真机一致，
  并断言失败清单为空。
- C 仓 c-test 101 项、chg / cool / state 单元测试共 76 项全过。

## 还没确认的

这两个问题会让温控表压根没生效，但「60% 掉到 20W」的直接成因仍需现场验证：
在 60%、20W 时把接管窗口拉到 90%（`action.sh fast 90`），若功率回到 40W 以上，
才是 `fast_cap` 交还壳温导致；若不动，则是充电 IC 层的降流，另有处理方向。
