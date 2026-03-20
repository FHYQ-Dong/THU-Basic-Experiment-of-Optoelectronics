# QKD-BB84 FPGA控制模块实现方案

## 1. 系统概述

本项目在 Artix-7 FPGA（xc7a35tfgg484-2，100MHz系统时钟）上实现BB84协议的硬件控制层，负责：

- 产生可调频率的同步时钟信号（供TCSPC使用），并从复位起累计同步脉冲计数
- 通过UART接收Alice计算机发来的单字节指令（编码bit值和偏振基选择）
- 在下一个sync上升沿触发对应激光器发射单光子
- 通过UART TX将该光子事件对应的32bit同步计数值发回上位机
- 循环上述流程，直到收到'q'（0x71）停止

---

## 2. 模块划分

```
top.v  （顶层模块）
├── sync_gen.v       同步信号发生器
├── uart_rx.v        UART接收器
├── uart_tx.v        UART发送器
└── laser_ctrl.v     激光器控制器
```

`data_buffer.v`（FIFO）已移除，改为严格的请求-响应协议。

### 2.1 顶层模块 `top.v`

负责连接各子模块，管理全局复位，暴露所有外部IO引脚，并实现主控FSM和sync计数器。

**端口：**

| 信号           | 方向   | 说明                    |
| -------------- | ------ | ----------------------- |
| `clk`        | input  | 100MHz系统时钟          |
| `rst`        | input  | 异步低有效复位          |
| `uart_rx`    | input  | UART数据输入            |
| `uart_tx`    | output | UART数据输出            |
| `sync_out`   | output | 同步信号输出（至TCSPC） |
| `laser[3:0]` | output | 4路激光器控制信号       |
| `led_empty`  | output | 状态指示LED（停止时亮） |

**参数（移除FIFO_DEPTH和SYNC_DIV）：**

| 参数                  | 默认值      | 说明              |
| --------------------- | ----------- | ----------------- |
| `CLK_FREQ`          | 100_000_000 | 系统时钟频率 (Hz) |
| `SYNC_FREQ`         | 1_000_000   | 同步信号频率 (Hz) |
| `SYNC_PULSE_WIDTH`  | 10          | 同步脉冲宽度（周期数）|
| `BAUD_RATE`         | 115_200     | UART波特率        |
| `LASER_PULSE_WIDTH` | 10          | 激光脉冲宽度（周期数）|

**sync计数器：**

从复位起，每个`sync_out`上升沿加1，自由运行的32bit计数器：

```verilog
reg        sync_prev;
wire       sync_rise = sync_out & ~sync_prev;
reg [31:0] sync_cnt;

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        sync_prev <= 0;
        sync_cnt  <= 0;
    end else begin
        sync_prev <= sync_out;
        if (sync_rise) sync_cnt <= sync_cnt + 1;
    end
end
```

**主控FSM（7状态）：**

```
S_WAIT_RX   → 等待rx_valid
S_CHECK_Q   → 检查是否为'q'(0x71)
S_WAIT_SYNC → 等待sync_rise
S_FIRE      → 触发激光（fire=1，持续1周期）
S_TX_LOAD   → 发送当前字节（tx_start=1，持续1周期）
S_TX_WAIT   → 等待tx_busy下降沿
S_STOPPED   → 停止状态（laser全0，不再TX）
```

**状态转移：**

| 当前状态 | 条件 | 下一状态 | 动作 |
|---|---|---|---|
| S_WAIT_RX | rx_valid | S_CHECK_Q | 锁存rx_data → data_latch |
| S_CHECK_Q | data_latch==0x71 | S_STOPPED | — |
| S_CHECK_Q | else | S_WAIT_SYNC | — |
| S_WAIT_SYNC | sync_rise | S_FIRE | 锁存sync_cnt → cnt_latch |
| S_FIRE | always | S_TX_LOAD | fire=1（1周期）; byte_idx=0 |
| S_TX_LOAD | always | S_TX_WAIT | tx_start=1（1周期），tx_data=cnt_latch对应字节 |
| S_TX_WAIT | tx_was_busy && ~tx_busy && byte_idx==3 | S_WAIT_RX | — |
| S_TX_WAIT | tx_was_busy && ~tx_busy && byte_idx<3 | S_TX_LOAD | byte_idx++ |
| S_TX_WAIT | tx_busy | S_TX_WAIT | tx_was_busy=1 |
| S_STOPPED | always | S_STOPPED | — |

**4字节发送顺序（大端序）：**

```
byte_idx 0 → cnt_latch[31:24]
byte_idx 1 → cnt_latch[23:16]
byte_idx 2 → cnt_latch[15:8]
byte_idx 3 → cnt_latch[7:0]
```

**LED逻辑：**

```verilog
assign led_empty = (state == S_STOPPED);  // 停止时LED亮
```

---

### 2.2 同步信号发生器 `sync_gen.v`

产生可调频率的同步脉冲，作为整个系统的时间基准。（无变化）

**参数：**

| 参数            | 默认值      | 说明                      |
| --------------- | ----------- | ------------------------- |
| `CLK_FREQ`    | 100_000_000 | 系统时钟频率 (Hz)         |
| `SYNC_FREQ`   | 1_000_000   | 同步信号频率 (Hz)，即1MHz |
| `PULSE_WIDTH` | 10          | 脉冲宽度（时钟周期数）    |

**逻辑：**

- 计数器从0计数到 `CLK_FREQ/SYNC_FREQ - 1`，每周期产生一个脉冲
- `sync_out` 在计数器 `< PULSE_WIDTH` 时为高，其余为低

---

### 2.3 UART发送器 `uart_tx.v`

每次光子事件后，向上位机发送4字节（32bit大端序sync计数值）。（模块本身无变化，触发逻辑移至top.v FSM）

**参数：**

| 参数          | 默认值      | 说明              |
| ------------- | ----------- | ----------------- |
| `CLK_FREQ`  | 100_000_000 | 系统时钟频率 (Hz) |
| `BAUD_RATE` | 115_200     | 波特率            |

**端口：**

| 信号       | 方向   | 说明                         |
| ---------- | ------ | ---------------------------- |
| `tx_data`  | input  | 待发送字节                   |
| `tx_start` | input  | 发送触发脉冲（1个时钟周期）  |
| `tx_busy`  | output | 发送中标志（高电平表示忙碌） |
| `uart_tx`  | output | 串行输出线                   |

---

### 2.4 UART接收器 `uart_rx.v`

接收来自Alice计算机的串行数据。（无变化）

**参数：**

| 参数          | 默认值      | 说明              |
| ------------- | ----------- | ----------------- |
| `CLK_FREQ`  | 100_000_000 | 系统时钟频率 (Hz) |
| `BAUD_RATE` | 115_200     | 波特率            |

**协议格式（每帧8N1）：**

- 1 bit起始位 / 8 bit数据 / 无校验位 / 1 bit停止位

**数据编码约定：**

每次发送1字节，只有低2bit有效：

| `data[1]`（基选择） | `data[0]`（bit值） | 激活激光器 | 偏振态    |
| --------------------- | -------------------- | ---------- | --------- |
| 0                     | 0                    | laser[0]   | 0°（H）  |
| 0                     | 1                    | laser[1]   | 90°（V） |
| 1                     | 0                    | laser[2]   | +45°     |
| 1                     | 1                    | laser[3]   | -45°     |

特殊字节：`0x71`（'q'）表示停止。

**输出信号：**

- `rx_data[7:0]`：接收到的字节
- `rx_valid`：数据有效脉冲（1个时钟周期高电平）

---

### 2.5 激光器控制器 `laser_ctrl.v`

接收fire脉冲和激光选择信号，驱动对应激光器输出固定宽度脉冲。（去掉FIFO接口，改为直接fire触发）

**参数：**

| 参数                  | 默认值 | 说明                       |
| --------------------- | ------ | -------------------------- |
| `LASER_PULSE_WIDTH` | 10     | 激光脉冲宽度（时钟周期数） |

**端口：**

| 信号         | 方向   | 说明                          |
| ------------ | ------ | ----------------------------- |
| `clk`      | input  | 系统时钟                      |
| `rst`      | input  | 异步低有效复位                |
| `laser_sel`| input  | 激光器选择 [1:0]（来自rx_data[1:0]）|
| `fire`     | input  | 触发脉冲（1个时钟周期）       |
| `laser`    | output | 4路激光器控制信号 [3:0]       |
| `busy`     | output | 脉冲输出中标志                |

**状态机（2状态）：**

```
S_IDLE: laser=0, busy=0
        fire=1 → 锁存laser_sel, pulse_cnt=0 → S_DRIVE

S_DRIVE: 根据锁存sel驱动one-hot laser, busy=1
         pulse_cnt++
         pulse_cnt == LASER_PULSE_WIDTH-1 → laser=0 → S_IDLE
```

**参数约束：**

```
LASER_PULSE_WIDTH < CLK_FREQ / SYNC_FREQ
```

默认参数下自动满足（10周期 < 100周期）。

---

## 3. 时序关系

```
uart_rx   ──[byte]──────────────────────────────────────────
                   │
top FSM            ▼ S_WAIT_SYNC
sync_out  ─┐  ┌──┐  ┌──┐
           └──┘  └──┘  └──
                      │
top FSM               ▼ S_FIRE → S_TX_LOAD → S_TX_WAIT(×4)
laser[i]              ┌─┐
                      └─┘ (LASER_PULSE_WIDTH周期)
uart_tx               ────[B3][B2][B1][B0]──── (4字节大端序sync计数)
```

每次光子事件：收到字节 → 等待下一sync上升沿 → 触发激光 → 发回4字节sync计数。

---

## 4. 仿真设计

每个模块配备独立 testbench，使用缩短的时钟/波特率参数加速仿真。

### 4.1 `tb_sync_gen.v`（无变化）

- 实例化 `sync_gen`，使用小参数（如 `CLK_FREQ=100, SYNC_FREQ=10, PULSE_WIDTH=2`）
- 验证：`sync_out` 周期正确、脉冲宽度正确

### 4.2 `tb_uart_rx.v`（无变化）

- 用任务 `send_byte(data)` 模拟串口发送
- 验证：`rx_valid` 在停止位后一周期拉高，`rx_data` 值正确

### 4.3 `tb_uart_tx.v`（无变化）

- 脉冲 `tx_start`，采样 `uart_tx` 输出，逐位验证
- 验证 `tx_busy` 行为

### 4.4 `tb_laser_ctrl.v`（更新）

- 直接驱动 `laser_sel` 和 `fire` 脉冲（无FIFO信号）
- 验证：`laser` 输出与 `laser_sel` 编码一致，`busy` 信号正确
- 验证脉冲宽度为 `LASER_PULSE_WIDTH` 周期

### 4.5 `tb_top.v`（重写）

- 顶层集成仿真，使用缩短参数（`BAUD_RATE` 调高、`SYNC_FREQ` 调低）
- 测试流程：
  1. Reset
  2. 发送字节 `0x00` → 等待sync脉冲触发 → 接收4字节sync计数值，验证正确
  3. 重复发送 `0x01`, `0x02`, `0x03`，验证对应激光器触发
  4. 发送 `0x71`（'q'）→ 验证激光全灭、无TX输出、`led_empty` 拉高

---

## 5. 文件结构

```
FPGA-control/
├── CLAUDE.md
├── plan/
│   └── implementation_plan.md      ← 本文件
├── user/
│   ├── src/
│   │   ├── top.v                   顶层模块（含主控FSM和sync计数器）
│   │   ├── sync_gen.v              同步信号发生器
│   │   ├── uart_rx.v               UART接收器
│   │   ├── uart_tx.v               UART发送器
│   │   └── laser_ctrl.v            激光器控制器（fire触发，无FIFO）
│   ├── sim/
│   │   ├── tb_top.v                顶层仿真testbench（重写）
│   │   ├── tb_sync_gen.v           同步模块仿真
│   │   ├── tb_uart_rx.v            UART接收仿真
│   │   ├── tb_uart_tx.v            UART发送仿真
│   │   └── tb_laser_ctrl.v         激光控制仿真（更新）
│   └── data/
│       └── top.xdc                 引脚约束文件
└── prj/                            Vivado工程目录
```

---

## 6. 关键参数汇总

| 参数         | 值                   | 备注                |
| ------------ | -------------------- | ------------------- |
| 系统时钟     | 100 MHz              | xc7a35tfgg484-2     |
| 同步信号频率 | 1 MHz（可调）        | 对应1μs时隙间隔    |
| UART波特率   | 115200 bps           | 标准波特率          |
| 激光脉冲宽度 | 10个时钟周期 = 100ns | 需小于同步周期1μs  |
| sync计数器   | 32bit，从复位起累计  | 大端序发回上位机    |

---

## 7. 约束说明

XDC文件需约束以下信号：

- `clk`：绑定至FPGA时钟引脚，添加 `create_clock` 约束
- `uart_rx`：绑定至UART RX引脚，设置输入延迟
- `uart_tx`：绑定至UART TX引脚
- `sync_out`：绑定至同步信号输出引脚
- `laser[3:0]`：绑定至4个激光器驱动引脚
- `led_empty`：绑定至板载LED引脚

具体引脚编号需根据实际PCB/开发板原理图确定后填入XDC。

---

## 8. 协议约定

上位机与FPGA通信协议（严格请求-响应）：

1. 上位机发送1字节：`data[1:0]` 编码激光器选择，其余bit忽略
2. FPGA在下一个sync上升沿触发激光，然后发回4字节（大端序32bit sync计数值）
3. 上位机收到4字节后，可发送下一字节
4. 上位机发送 `0x71`（'q'）时，FPGA停止工作（复位前不再响应）

**注意：** S_WAIT_SYNC期间若有新UART字节到达，将被丢弃。协议保证上位机在收到4字节响应前不发送下一字节。
