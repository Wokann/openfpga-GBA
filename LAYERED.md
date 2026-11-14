# Layered：SD ROM 与实体卡带存档

本分支以 mincer-ray/openfpga-GBA **v1.0.1 / a61eaf2** 为基线，将旧版
`f245435` 中已经调试过的存档通路和卡带 ROM 头探测筛选后合并为一个提交。
旧版完整历史保存在 `backup/layered-20260814`，`master` 保持与上游一致。

## 本次迁移范围

- 游戏 ROM 始终来自 SD 卡；实体 ROM 只用于启动时的卡带存在性探测。
- SRAM/Flash 的字节访问及 Flash 解锁、编程、擦除、bank 切换命令转发给
  卡带芯片，不经过内部 Flash 命令模拟器。
- EEPROM 按位转发，保留 DMA 连续片选、读写方向切换时的命令锁存和 CPU
  就绪轮询。EEPROM 的片选为 ROMCS，A23 保持高，数据为 AD0。
- 启动时将实体 ROM 的 `0xB0..0xBF` 读两遍；两遍一致、整个范围既非全零
  也非全 FF 才启用卡带存档。超时、空槽或不一致则回退上游 SD 存档。
- AD[15:0] 保留旧版的弱上拉配置。

不迁移旧版 GPIO/RTC 转发、GPIO 时序扫描、诊断寄存器、SD 日志槽，以及
切换游戏 ROM 来源的实验代码。卡带头判定只是存在性检查，不能保证所有
引脚接触良好，也不验证实体卡带和所选 SD ROM 的存档格式是否匹配。

## 与上游 RTC、震动共存

上游内部模拟 RTC、独立 `.rtc` 文件及 GPIO 读取使能逻辑保持不变；本分支
没有读取实体卡带 RTC 的能力。原 `data.json` 不变，不复用 RTC 的槽 ID 11。

上游震动驱动与新存档控制器共用物理卡槽，通过跨时钟域的四阶段请求／授权
握手交接引脚。震动的一次更新（方向写入和数据写入）完整结束后才交出总线；
存档控制器在取得授权前锁存请求并等待。EEPROM 的整个连续会话（含位间空闲
和方向切换）保持独占，结束或超时后才允许震动写入。

## 设置与存档隔离

英文菜单 `Cartridge Saves` 默认开启。修改后重置核心并重新探测卡带，
当前游戏运行期间不重新探测热插拔。关闭设置或探测失败时使用上游存档逻辑。
切换存档来源不会在 SD 与卡带之间复制存档；要更换 SD 游戏，应重新加载 ROM。

卡带模式启用后，游戏内的 SRAM/Flash/EEPROM 访问只走实体卡带，并向 Pocket
报告 `.sav` 写回尺寸为零。启动时平台仍可能传入 SD 存档，这些数据只进入
上游独立的 PSRAM 加载通路，不会写入卡带；该通路也保留了回退到 SD 存档的
能力。上游 `.rtc` 继续为内部模拟时钟独立加载／写回。

安装本分支的构建时，需同时更新 `bitstream.rbf_r` 和 `interact.json`。

## 源码组织

新增硬件模块与上游的存档／RTC 模块同放在 `src/fpga/core/`；回归脚本和测试
文件同放在已有的 `scripts/`，不建立新的功能目录。

接入位置按 v1.0.1 的现有数据流选择：

- 保留 `apf_write_ingress` 的有序加载和完成屏障，保留 PSRAM 加载／清除／卸载
  协议；不恢复旧版的三个独立 `data_loader`。
- 在 `core_top` 现有 `bus_out` 仲裁中增加卡带存档分支，EWRAM 继续使用新基线
  的 SDRAM 通道和 byte enable。
- 在 `gba_memorymux` 原有 Flash／EEPROM 入口按一个模式位分流；内部 Flash
  状态机、GPIO 读取使能和 RTC 实现沿用上游。
- 在上游现有的震动写周期之间交接引脚，不另建 GPIO/震动实现。卡带控制器
  只保留头部索引读取和存档协议，去掉通用 ROM 地址路径、重复数据缓存、
  调试输出及无用状态，计数器宽度按实际等待参数计算。

## 验证

安装 Python、Icarus Verilog 和 GHDL 后运行：

```sh
python scripts/test_layered.py
```

也可以通过 `IVERILOG`、`VVP`、`GHDL` 环境变量指定可执行文件路径。
临时仿真文件放在系统临时目录并自动清理。GHDL 使用上游 RAM 的行为实现；
仅在临时副本中去掉 Intel 原语分支，不修改生产 RAM 文件。

回归覆盖实际顶层的震动／存档总线集成、震动期间排队的 SRAM 请求、连续存档
访问、Flash bank 1、EEPROM DMA／CPU 轮询、ROM 头匹配／全 FF／全零／末字
不一致／超时，以及真实 VHDL memorymux 的 Flash 命令透传、EEPROM 半字旋转、
GPIO 读取使能和关闭模式后的上游回退。分支 CI 在 Quartus 构建前运行同一回归。
行为模型通过不等于已完成 Pocket 真机验收，特别是 Flash1M 和震动／存档并发。

## 参考

- [上游 v1.0.1 发布说明](https://github.com/mincer-ray/openfpga-GBA/releases/tag/v1.0.1)
- [RTC 独立文件变更](https://github.com/mincer-ray/openfpga-GBA/pull/41)
- [上游 GPIO 读取使能变更](https://github.com/mincer-ray/openfpga-GBA/commit/db4132854768463a4e052659195991cfc5f143d4)
- 旧版卡带总线控制器和实测记录保留在备份分支；本次不逐条重放其提交。
