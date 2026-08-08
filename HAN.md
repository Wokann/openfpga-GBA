# HAN：GBA 汉化双模式扩展（进行中）

本 fork 在 [mincer-ray/openfpga-GBA](https://github.com/mincer-ray/openfpga-GBA)（MiSTer GBA 核心的 Analogue Pocket 移植）基础上扩展，目标是为实体 GBA 卡带提供汉化支持。

## 模式定义

- **迂回汉化（当前实现重点）**：运行 SD 卡中的 GBA ROM（汉化版），存档与扩展硬件（RTC/震动/太阳感应/陀螺仪）全部通过 Pocket 卡带槽上的实体卡带读写。
- **外挂汉化（规划中）**：运行实体卡带 ROM，SD 卡存放 IPS/UPS 补丁，核心实时替换 ROM 数据。

## 当前实现（理论逻辑完成，待真机验证）

### 新增模块（`src/fpga/han/`）

- `gba_cart_controller.sv`：GBA 卡带总线控制器
  - ROM 读：16-bit CS1# 读（供外挂模式，当前默认关闭）
  - 存档访问：8-bit CS2# SRAM/Flash 字节读写（Flash 命令由实体芯片自响应）
  - EEPROM：经 A23/RAMCS/D0 的位串行转发
  - GPIO：16-bit 读写 0x080000C4..0x080000C8（RTC/太阳/陀螺/震动硬件）
- `rom_source_mux.sv`：ROM 读路径选择（SD SDRAM ↔ 卡带）

### 接入点（`src/fpga/core/core_top.sv`）

- 卡带槽引脚由 `u_gba_cart` 驱动（原为闲置高阻）
- `bus_out` 存档访问：`han_save_cart_mode` 为 1 时路由到卡带控制器
- GPIO：`gba_top.vhd` 新增 GPIO 桥端口，`han_gpio_cart_mode` 为 1 时由卡带控制器应答
- ROM 源：`han_rom_cart_mode` 控制（当前默认 0 = SD，外挂模式后续启用）

### 模式开关（`core_top.sv` 顶部）

```systemverilog
assign han_rom_cart_mode  = 1'b0;   // 外挂：ROM 走卡带（未来）
assign han_save_cart_mode = 1'b1;   // 迂回：存档走卡带
assign han_gpio_cart_mode = 1'b1;   // 迂回：GPIO 走卡带
```

注意：当前为验证迂回汉化，存档/GPIO 默认走卡带；不插卡带时存档会异常（读回无效值）。

## 仿真测试（`sim/han/`）

```bash
cd sim/han
iverilog -g2012 -o tb.vvp ../../src/fpga/han/gba_cart_controller.sv ../../src/fpga/han/rom_source_mux.sv tb_gba_cart_controller.sv
vvp tb.vvp
```

覆盖：ROM 读、SRAM 写/读回、GPIO 读/写、EEPROM 位转发。CI（`.github/workflows/build-branch.yml`）在编译前自动运行。

## 已知限制 / 待真机校准

- 总线时序参数（ROM_WAIT/SAVE_WAIT/ADDR_SETUP）为保守占位，需真机卡带校准
- EEPROM/Flash 为透明转发实现，依赖实体芯片自响应；协议细节（尤其 EEPROM 引脚时序）需真机验证
- GPIO 实体硬件（RTC 芯片协议、震动驱动、光传感器、陀螺仪）尚未针对具体卡带验证
- 存档类型由 `gba_top` 的 save_sram/save_flash/save_eeprom 信号选择，卡带与 SD 存档类型不一致时行为未定义
