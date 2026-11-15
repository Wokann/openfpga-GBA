# mincer_ray-AGBLayered：SD ROM 与实体卡带存档、外设

原作者 mincer_ray；Wokann 基于 AI 生成并添加卡带硬件直通、卡带存档读取与写入功能。

本分支以 mincer-ray/openfpga-GBA **v1.0.1 / a61eaf2** 为基线，将旧版
`f245435` 中已经调试过的存档通路和卡带 ROM 头探测筛选后合并为一个提交。
旧版完整历史保存在 `backup/layered-20260814`，`master` 保持与上游一致。

## 本次迁移范围

- 游戏 ROM 始终来自 SD 卡；实体 ROM 只用于启动或重新启用外设时的卡带存在性探测。
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

启用实体外设时，将 `0x080000C4/C6/C8` 的数据、方向、读取使能寄存器直接转发到
实体卡带，包含全部四位 GPIO。RTC、太阳能、陀螺仪、GPIO3 震动的协议由
游戏和卡带芯片处理；FPGA 不识别或模拟这些外设，也不依赖 ROM 数据库的
GPIO 标记。访问使用半字总线周期；读写都等待物理传输结束才完成 CPU 请求。

32 位访问按 ARM 对齐规则处理：C4/C6 拆成两次半字传输；C8/CA 读取时，
C8 来自卡带、CA 仍来自 SD ROM，写入时忽略普通 ROM 的 CA。支持字节读取、
非对齐读取的旋转，以及 08/0A/0C ROM 等待区的地址映射。STRB 字节写入
兼容上游本地 GPIO 的处理：将源寄存器低 8 位零扩展，作为一次 16 位卡带事务
写入对应 GPIO 半字寄存器，不进行额外的读改写。GBATEK 明确列出 16/32 位
ROM 总线访问，但对忽略 STRB 是否仅限 DS 模式标有疑问；这里的 8 位转换是
兼容策略，不声称复现了所有原机的 STRB 电气行为。普通 ROM 地址不因此开放写入。

GPIO 半字响应先在专用 32 位寄存器中拼装，完成后用一个独立状态一次性提交到
公共 `rotate_data`，减少公共读回寄存器上的条件更新。每次 GPIO 读取因此多一个
核心时钟，约 9.93 ns；卡带事务波形和存档路由不变。回归另包含 120 组读取，
每次先将公共结果填入非零值，再验证字节／半字／整字、非对齐旋转和 ROM 等待区映射。

C8=0 时读取仍走 SD ROM，不强行返回零，也不会落入本地 RTC。C8 的读取
使能记录仅在实体写入完成后更新。每次核心重启或重新启用外设、成功探测 GBA 卡后，只初始化一次
C8=0，并等待完成后释放游戏启动等待或总线暂停；不初始化 C4/C6，不发送 RTC 命令。

关闭实体外设或卡带探测失败时，上游内部 GPIO/RTC、独立 `.rtc` 文件和震动驱动
恢复原有行为。原 `data.json` 不变，不复用 RTC 的槽 ID 11。

只检查卡带是否存在，不读取游戏 ID 判断它安装了哪些外设。插入不含所需
外设的卡带时，游戏自行处理总线返回值；不会在事务中途猜测失败并混入模拟。
回退沿用当前基线能力：RTC 模拟和震动仍有实现，光感、陀螺仪输入已被基线
裁剪，倾斜模拟入口在顶层关闭；“回退”不等于这些模拟外设已补齐。

上游震动驱动在回退模式或 DS 震动卡适配模式运行。探测期间及实体外设模式全程禁止其周期刷新，
包括 GPIO 事务之间的空闲时间，避免方向写入、AD1 翻转干扰 RTC 串行会话。
正卡震动来自游戏自己的 GPIO3 写入，可与其他 GPIO 和存档共存。模式切换时，
已经开始的上游震动更新先完整结束，再通过原有四阶段跨时钟域握手交出总线。
EEPROM 连续会话保留原有独占与超时机制。

## DS 震动卡与 EZ 震动补丁

标准 DS Rumble Pak（AD1 脉冲型）单独探测和适配：探测采用 GBATEK 的地址回显且 AD1 为低的特征；也接受 `FFFD` 弱上拉响应，后者是针对本核心总线的兼容假设，仍需真机确认。两遍读数必须一致。
DS 卡不被当成 GBA 存档卡，也不启用 PHI、卡槽 IRQ 或倾斜传感器；存档保持 SD 路由。
外设开启且识别为 DS 卡时，C4/C6/C8 进入独立的 GPIO3 适配状态，经上游 AD1 驱动输出震动，不经过 ROM ID、Force 或本地 RTC。DS 卡没有实体 RTC、光感或陀螺仪，适配器不会假装提供这些硬件。
外设关闭或空槽时恢复上游本地逻辑，Force 保留原有用途。这里只支持标准 AD1 型 DS 震动协议，不宣称覆盖所有第三方 DS 扩展卡。

在 GBA/DS 实体外设路由下，额外识别 EZ 完整解锁、震动寄存器、提交序列：

- `09FE0000=D200 → 08000000=1500 → 08020000=D200 → 08040000=1500 → 09E20000=命令 → 09FC0000=1500`。
- EZ 3-in-1 补丁的 `1/3/7` 转为震动开启，`0/8` 转为关闭。
- EZODE 的 `F0/F1/F2` 只启用转换端口；之后 `08001000` 的 bit1 控制震动，支持字节、半字、整字写入。
- 解锁/命令序列使用半字或整字写入；孤立的端口写、错误序列和其他烧录卡命令不触发转换。

转换复用 C6/C4 两个 GPIO 半字事务，只修改 GPIO3，保留游戏最近写入的 GPIO0～2 数据与方向，不写 C8，不发送额外 RTC 命令。
两次事务都结束才完成 CPU 请求，切换也会等待其完成。原生 GPIO 写入仍直接生效；同时包含 EZ 和 GPIO 的补丁按程序顺序执行。
强度目前归一为开／关；不模拟不同马达的物理强度，也不模拟完整 EZ 烧录卡。
关闭实体外设或重新探测会清除 EZODE 的启用状态；EZODE-only 软件可能需要重发初始化序列。

## 设置与存档隔离

英文菜单分别提供 `Cartridge Saves`（原 ID 40 / 0x90）与
`Peripheral Passthrough`（ID 41 / 0x94），默认均开启。外设开关即时生效，不重启游戏：先暂停新内存请求，等待在途事务和卡槽所有权交接结束，再切换路径；开启时重新探测卡带。
`Cartridge Saves` 修改后仍重启。卡带存档开启时强制启用实体外设，外设开关的独立选择适用于 SD 存档模式。
单纯插拔不会触发自动检测；SD 存档模式下关闭再开启外设开关可重新探测。
切换不会迁移本地与实体 RTC 的串行会话状态，游戏可能需要重新初始化外设。

| 卡带存档 | 外设透传偏好 | 检测到卡带时的行为 |
|---|---|---|
| 关闭 | 关闭 | SD 存档＋上游 GPIO/RTC 与震动驱动 |
| 关闭 | 开启 | SD 存档＋实体 GPIO、倾斜传感器、PHI 与 IRQ |
| 开启 | 任意 | 实体存档＋实体 GPIO、倾斜传感器、PHI 与 IRQ |

表中实体存档与非 GPIO 外设指检测到 GBA 卡的情况；DS 震动卡只适配震动，存档仍为 SD。
空槽或探测失败均回退上游。关闭“外设透传”是恢复基线，因此基线原有的
实体震动驱动仍可运行；它不是所有震动的总开关。

实体外设模式同时接通以下非 GPIO 通路：

- **倾斜传感器**：复用上游对所运行 SD ROM 的 `KYG/KHP` 倾斜游戏标记，将
  `0x0E008000/8100/8200/8300/8400/8500` 六个字节寄存器送到卡带。这里的
  标记只用于区分地址含义，不识别所插卡带是否真的具有传感器。其他 SRAM
  游戏的同地址仍按存档处理，倾斜游戏的 EEPROM 也继续按独立存档开关分流。
  传感器写入不触发 SRAM 存档脏标记。
- **PHI**：跟随游戏 `WAITCNT[12:11]`，提供关闭、GBA 时钟 /4、/2、/1
  （约 4.19/8.39/16.78 MHz）。由一个持续的引脚驱动器输出，总线交接、
  GPIO 或存档事务不会切断 PHI；复位或退出实体外设模式时关闭。
- **卡槽 IRQ**：读取 pin31，经三级同步后捕获上升沿，接入真实 `IF[13]`
  和上游 IE/IME 中断通路。软件写一清除，不因引脚持续为高反复触发；核心
  暂停时也保留请求。刚进入模式时先同步初始电平，避免伪造一次中断。

不模拟 RTC 的闹钟或周期中断算法，只接收实体卡带给出的电平变化。RTC
引脚经过卡带 ROM 芯片反相后到达卡槽，因此不再额外反相；具体哪些商业游戏
使用其 IRQ、各卡带的时序与电气表现，仍需要真机确认。
切换存档来源不会在 SD 与卡带之间复制存档；要更换 SD 游戏，应重新加载 ROM。

卡带存档启用后，游戏内的 SRAM/Flash/EEPROM 访问只走实体卡带，并向 Pocket
报告 `.sav` 写回尺寸为零。`.rtc` 的写回尺寸则只由实体 GPIO 是否启用决定，
因此 SD 存档＋实体 GPIO 时仍正常保存 `.sav`，不会导出本地 `.rtc`。
启动时平台仍可能传入 SD 存档，这些数据只进入
上游独立的 PSRAM 加载通路，不会写入卡带；该通路也保留了回退到 SD 存档的
能力。实体 GPIO 模式不把 `.rtc` 加载为本地 RTC 状态，也不会用 Pocket 时间设置
实体 RTC；回退时继续使用上游 `.rtc` 加载／写回。

安装时复制完整包的 `Cores/`、`Platforms/`、`Assets/` 到 SD 卡。
核心显示名为 `mincer_ray-AGBLayered`，目录为 `/Cores/mincer_ray.AGBLayered/`，遵循固件要求的 `作者.核心名` 格式。
ROM 和普通存档目录仍是 `/Assets/gba/common/` 与 `/Saves/gba/common/`；核心菜单设置及 Memories 归属新的核心标识。

## 源码组织

卡带总线和探测模块与上游的存档／RTC 模块同放在 `src/fpga/core/`；回归脚本和测试
文件同放在已有的 `scripts/`，不建立新的功能目录。
PHI/IRQ 的小型 VHDL 模块 `gba_cart_io` 放在已有 `src/fpga/gba/`，与
`gba_top` 的 WAITCNT 和中断控制直接连接。

接入位置按 v1.0.1 的现有数据流选择：

- 保留 `apf_write_ingress` 的有序加载和完成屏障，保留 PSRAM 加载／清除／卸载
  协议；不恢复旧版的三个独立 `data_loader`。
- 在 `core_top` 现有 `bus_out` 仲裁中增加卡带存档分支，EWRAM 继续使用新基线
  的 SDRAM 通道和 byte enable。
- 在 `gba_memorymux` 原有 Flash／EEPROM／GPIO 入口按独立模式位分流；内部
  Flash 与 GPIO/RTC 实现作为回退保留。复用上游 ROM 缓存与读取旋转状态。
- 在现有卡带控制器里扩展 GPIO 事务，不新增生产模块或目录。GPIO 复用上游
  震动写入的六阶段波形，按 100 MHz 时钟换算为每阶段 27 周期；读取时增加
  AD 总线转向与采样。沿用原有卡槽仲裁和请求锁存，不恢复旧版 GPIO 扫描代码。

## 验证

安装 Python、Icarus Verilog 和 GHDL 后运行：

```sh
python scripts/test_layered.py
```

也可以通过 `IVERILOG`、`VVP`、`GHDL` 环境变量指定可执行文件路径。
临时仿真文件放在系统临时目录并自动清理。GHDL 使用上游 RAM 的行为实现；
仅在临时副本中去掉 Intel 原语分支，不修改生产 RAM 文件。

回归直接提取生产顶层的总线集成，使用实际控制器检查：全部 16 种 GPIO 方向、
输入输出回读、RTC 风格的串行命令及响应、RTC 位间插入存档访问、GPIO3 状态
保持、跨越完整刷新周期没有额外震动写入、关闭与空卡后的震动回退。原 SRAM、
Flash bank 1、EEPROM DMA／CPU、ROM 头匹配／异常／超时测试继续保留。

真实 VHDL memorymux 仿真检查实体写入等待、字节／半字／整字读取、整字拆分、
非对齐旋转、ROM 等待区映射、C8/CA 混合读取的缓存命中与缺失、C8 关闭后的 SD
ROM 返回，以及回退分流。分支 CI 在 Quartus 构建前运行同一回归。

另使用 Pinball 中文补丁 1.2/1.3 的原始 C8/C6/C4 字节写入序列验证 SD 存档＋
实体 GPIO，覆盖 Force Quirk 组合输入开／关、震动开／关、源寄存器高位非零、
六个 GPIO 字节地址及三个 ROM 等待区。16/32 位写入、普通 ROM 地址隔离、EZ 解锁校验和 RTC 位保留同时回归；EZ 命令仅转换为受控 GPIO 写入，不直接透传烧录卡命令地址。

新增回归检查 DS 地址/弱上拉特征、运行中切换、在途事务完整结束、暂停请求按新路径继续，以及 EZ 3-in-1/EZODE 转换与关闭隔离。

非 GPIO 回归覆盖六个传感器地址与相邻普通存档地址的隔离、SD EEPROM
不被传感器模式改成实体存档、PHI 连续性与四档输出。IRQ 测试直接提取
生产 `gba_top` 的中断过程，检查暂停捕获、IE/IME 屏蔽、IF 写一清除、同周期
新事件优先，以及关闭/重新启用时不产生伪中断。生产 memorymux 和 cart_io
还检查 VHDL-2002 兼容性。

行为模型通过不等于 Pocket 真机验收；实体 RTC、太阳能、陀螺仪、震动组合，
以及新增的倾斜传感器、PHI、IRQ 通路仍需上机测试。本次不实现卡槽 /DREQ
触发的特殊 DMA 协议。实体外设状态也不能随 FPGA 即时存档倒退恢复。

## 参考

- [EZ 官方开发文档，第 4 页震动协议](https://github.com/ez-flash/omega-de-kernel/blob/main/EZ-FLASH%20OMEGA%20DE%20DOCUMENT.pdf)
- [asie's EZ 接口研究记录：解锁与强度寄存器](https://wiki.asie.pl/doku.php?id=notes:flashcart:ezflash)
- 本地 Pinball 中文补丁 `src/00-07_087E0340_RumbleSwitch.s` 提供 3-in-1 的 `1/3/7`、`0/8` 序列；这些值作为补丁兼容范围，不宣称完整硬件规格。
- [GBATEK DS Rumble Pak（mGBA 镜像）](https://mgba-emu.github.io/gbatek/#ds-cart-rumble-pak)
- [Analogue 核心目录命名规范](https://www.analogue.co/developer/docs/openfpga/directories-and-sd-folder-structure)


- [上游 v1.0.1 发布说明](https://github.com/mincer-ray/openfpga-GBA/releases/tag/v1.0.1)
- [RTC 独立文件变更](https://github.com/mincer-ray/openfpga-GBA/pull/41)
- [上游 GPIO 读取使能变更](https://github.com/mincer-ray/openfpga-GBA/commit/db4132854768463a4e052659195991cfc5f143d4)
- [GBATEK GPIO 寄存器及外设接线](https://problemkaputt.de/gbatek.htm#gbacartioportgpio)
- [上游实体 GPIO 震动写入波形](https://github.com/mincer-ray/openfpga-GBA/commit/ab4132ee8d81fcda3b79196fcefea6c50f7c42b7)
- [GBATEK 倾斜传感器寄存器与 PHI](https://problemkaputt.de/gbatek.htm#gbacarttiltsensor)
- [ares 的卡带 RTC 中断边沿实现](https://github.com/ares-emulator/ares/blob/master/ares/gba/cartridge/rtc.cpp)
- 旧版卡带总线控制器和实测记录保留在备份分支；本次不逐条重放其提交。
