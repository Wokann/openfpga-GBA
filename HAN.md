# HAN：GBA 汉化双模式扩展（进行中）

本 fork 在 [mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA)
（MiSTer GBA 核心的 Analogue Pocket 移植版，上游 v0.6.2）基础上扩展，目标是为
实体 GBA 卡带提供汉化支持。

## 模式定义

- **迂回汉化（当前实现重点）**：运行 SD 卡中的 GBA ROM（汉化版），存档与扩展
  硬件（RTC/震动/太阳感应/陀螺仪）全部通过 Pocket 卡带槽上的实体卡带读写。
- **外挂汉化（规划中）**：运行实体卡带 ROM，SD 卡存放 IPS/UPS 补丁，核心实时
  替换 ROM 数据。

## 当前实现（理论逻辑完成，待真机验证）

### 新增模块（`src/fpga/han/`）

- `gba_cart_controller.sv`：GBA 卡带总线控制器
  - ROM 读：16-bit CS1# 读。时序按 jojolebarjos/gba-cartridge 实测协议：
    先驱动完整 24 位地址 → CS# 下降沿锁存地址 → 释放 AD → RD# 下降沿取数 →
    采样后 RD# 上升沿结束本次读（供外挂模式，当前默认关闭）
  - 存档访问：8-bit SRAM/Flash 经 CS2#。**数据走 A[23:16]（bank1），地址走
    AD[15:0]（bank2/bank3）**，符合实测协议；Flash 命令由实体芯片自行响应
  - EEPROM：**位级透传**（A23=时钟、D0=数据、RAMCS=CS2#）。核心不再模拟
    EEPROM 协议，每次 CPU/DMA3 对 0x0Dxxxxxx 区的访问转发为一个位，物理
    EEPROM 芯片自行解析命令流
  - GPIO：16-bit 读写 0x080000C4..0x080000C8（RTC/太阳/陀螺/震动硬件）
- `rom_source_mux.sv`：ROM 读路径选择（SD SDRAM ↔ 卡带，外挂模式用）

### 接入点（`src/fpga/core/core_top.sv`）

- 卡带槽引脚由 `u_gba_cart` 驱动（原为闲置高阻）
- `bus_out` 存档访问：`han_save_cart_mode=1` 时路由到卡带控制器
- GPIO：`gba_top.vhd` 新增 GPIO 桥端口，`han_gpio_cart_mode=1` 时由卡带控制器应答
- EEPROM：`gba_memorymux.vhd` 新增 `EEPROM_cart_mode` 位级转发端口，
  `gba_top.vhd`/`core_top.sv` 打通链路，`han_eeprom_cart_mode=1` 时启用

### 模式开关（`core_top.sv` 顶部）

```systemverilog
assign han_rom_cart_mode    = 1'b0;   // 外挂：ROM 走卡带（未来）
assign han_save_cart_mode   = 1'b1;   // 迂回：存档走卡带
assign han_gpio_cart_mode   = 1'b1;   // 迂回：GPIO 走卡带
assign han_eeprom_cart_mode = 1'b1;   // 迂回：EEPROM 位流走卡带
```

注意：当前为验证迂回汉化，存档/GPIO/EEPROM 默认走卡带；不插卡带时存档会
异常（读回无效值）。

## 仿真测试（`sim/han/`）

```bash
cd sim/han
iverilog -g2012 -o tb.vvp ../../src/fpga/han/gba_cart_controller.sv ../../src/fpga/han/rom_source_mux.sv tb_gba_cart_controller.sv
vvp tb.vvp
```

覆盖：ROM 读、SRAM 写/读回（bank1 数据路径）、GPIO 读/写、EEPROM 位握手。
CI（`.github/workflows/build-branch.yml`）在编译前自动运行。

## 时序依据与已知限制 / 待真机校准

- **卡带协议依据**（已核对）：
  - jojolebarjos/gba-cartridge 实测：ROM 访问 CS# 下降沿锁存地址、RD# 下降沿
    取数、RD# 上升沿地址自增；SRAM 数据走 A[23:16]（原实现误放 AD 低字节，
    已修正）
  - GBATEK（WAITCNT，默认 4317h）：WS0/ROM=3,1 clks；SRAM=8 clks；
    WS2/EEPROM=8,8 clks；PHI 终端默认禁用（控制器已按此默认拉高 PHI）
  - DenSinH GBA EEPROM 文档：D0 数据位、A23 时钟、6/14 位地址、64 位块
  - GBATEK EEPROM 章节（关键修正）：DMA3 传输期间 ROMCS(/CS2#) 保持低、
    **A23 保持高**，每个位由一次 16 位 DMA 访问（RD#/WR# 脉冲）驱动，数据
    在 AD0；地址为 6 位（512B）或 14 位（8KB，只用低 10 位）；写后需轮询
    DFFF00h 的 bit0 直到返回 1（Ready）。控制器已按"CS2# 低 + A23 高 +
    RD#/WR# 脉冲"实现位转发（早期 A23 脉冲版本已废弃）
  - GBATEK GPIO 章节：80000C4h=C4 数据/C6 方向/C8 控制（4bit），RTC 经
    GPIO 3 线串行访问（SCK/SIO/CS），与控制器 16 位 R/W 桥一致
- **时序参数**（ROM_WAIT/SAVE_WAIT/ADDR_SETUP/EEPROM_HALF_CYCLE）为保守
  占位值，需真机卡带校准
- **EEPROM 位时钟极性**：GBATEK 明确 A23 恒高、位由 RD#/WR# 脉冲驱动，
  但 RD#/WR# 脉冲宽度、D0 建立/保持时间仍需真机校准（nds-slot2 项目注明
  GBA 槽无官方完整时序图）
- **GPIO 实体硬件**：RTC 芯片协议、震动驱动、光传感器、陀螺仪尚未针对
  具体卡带验证
- 存档类型由 `gba_top` 的 save_sram/save_flash/save_eeprom 信号决定；
  卡带与 SD 存档类型不一致时行为未定义（迂回模式应插同类型卡带）
