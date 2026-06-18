# QKD-BB84 FPGA控制模块实现方案

> 本文档是 **已落地实现** 的方案。`实际代码` 一栏与 `user/src/*.v` 完全一致，
> 与早期 plan 不符之处在末尾"与初版 plan 的差异"小节中列出。

## 1. 系统概述

在 Artix-7 FPGA（`xc7a35tfgg484-2`，100 MHz 系统时钟）上实现 BB84 协议的硬件控制层：

- 产生可调频率的同步脉冲（供 TCSPC 做时间基准）
- 通过 UART 接收 Alice 计算机发来的单字节指令（编码 bit 值 + 偏振基选择）
- 在下一个 sync 上升沿触发对应激光器发射单光子脉冲
- 循环上述流程，直到收到 `'q'`（`0x71`）停止

---

## 2. 模块划分

```
top.v  （顶层 + 主控 FSM）
├── sync_gen.v       同步信号发生器
├── uart_receiver.v  UART 接收器（文件名 uart_rx.v）
└── laser_ctrl.v     激光器控制器
```

> **状态**：`user/src/` 下还残留 `data_buffer.v`（FIFO）与 `uart_tx.v`（UART 发送器）。
> 它们 **不被 `top.v` 引用**，是从早期带 FIFO + 回传时间戳方案保留下来的死代码。
> 当前数据流极简：UART 一字节进 → 等下一 sync → 触发激光，无需缓存。
> 可以删除以减少混淆，但保留也不影响综合（`top.v` 不实例化它们）。

### 2.1 顶层模块 `top.v`

连接所有子模块，管理同步上升沿检测和主控 FSM。

**端口：**

| 信号           | 方向   | 说明                              |
| -------------- | ------ | --------------------------------- |
| `clk`          | input  | 100 MHz 系统时钟                  |
| `rst`          | input  | **同步、高有效**复位（`rst=1` 复位）|
| `uart_rx`      | input  | UART 数据输入                     |
| `sync_out`     | output | 同步信号输出（至 TCSPC）          |
| `laser[3:0]`   | output | 4 路激光器控制信号                |
| `laser_en`     | output | 激光使能（任一 `laser` 为 1 时为 1）|
| `led_empty`    | output | 状态指示 LED（**收到首字节后常亮**，调试用）|

**参数（默认值）：**

| 参数                  | 默认值       | 说明                              |
| --------------------- | ------------ | --------------------------------- |
| `CLK_FREQ`            | 100_000_000  | 系统时钟 (Hz)                     |
| `SYNC_FREQ`           | 50_000       | 同步信号频率 (Hz)，即 50 kHz      |
| `SYNC_PULSE_WIDTH`    | 1000         | 同步脉冲宽度（10 µs ≈ TCSPC 输入要求）|
| `BAUD_RATE`           | 250_000      | UART 波特率（与 `Alice/random-gen.py` 一致）|
| `LASER_PULSE_WIDTH`   | 1000         | 激光脉冲宽度（10 µs，恰好与 sync 周期 20 µs 错开）|

**主控 FSM（4 状态）：**

```
S_WAIT_RX   → 等待 rx_valid
S_CHECK_Q   → 检查是否为 'q' (0x71)
S_WAIT_SYNC → 等待 sync_rise，触发 fire
S_STOPPED   → 停止状态
```

| 当前状态     | 条件                  | 下一状态      | 动作                                  |
| ------------ | --------------------- | ------------- | ------------------------------------- |
| `S_WAIT_RX`  | `rx_valid`            | `S_CHECK_Q`   | 锁存 `rx_data → data_latch`           |
| `S_CHECK_Q`  | `data_latch == 0x71`  | `S_STOPPED`   | —                                     |
| `S_CHECK_Q`  | else                  | `S_WAIT_SYNC` | —                                     |
| `S_WAIT_SYNC`| `sync_rise`           | `S_WAIT_RX`   | `fire <= 1`（单周期）                  |
| `S_STOPPED`  | 总成立                 | `S_STOPPED`   | —                                     |

**辅助逻辑：**

```verilog
// laser_en: 任一激光器为高即拉高
assign laser_en = |laser;

// sync_rise: 用 1 拍延迟实现上升沿检测
reg sync_prev;
wire sync_rise = sync_out & ~sync_prev;
always @(posedge clk) sync_prev <= rst ? 1'b0 : sync_out;

// led_empty: 调试用，收到任意 UART 字节后常亮，便于排查 RX 物理链路
reg dbg_rx_seen;
always @(posedge clk)
    if (rst)           dbg_rx_seen <= 0;
    else if (rx_valid) dbg_rx_seen <= 1;
assign led_empty = dbg_rx_seen;
```

> **注意**：`led_empty` 当前 **不再是"停止指示"**，而是 RX 物理链路联通指示。
> 如果需要恢复"停止灯"语义，把最后一行换成 `assign led_empty = (state == S_STOPPED);` 即可。

---

### 2.2 同步信号发生器 `sync_gen.v`

| 参数            | 默认值        | 说明              |
| --------------- | ------------- | ----------------- |
| `CLK_FREQ`      | 100_000_000   | 系统时钟 (Hz)     |
| `SYNC_FREQ`     | 1_000_000     | 同步信号频率 (Hz) |
| `PULSE_WIDTH`   | 10            | 脉冲宽度（时钟周期数）|

逻辑：32 bit 计数器从 0 计到 `CLK_FREQ/SYNC_FREQ - 1`，`cnt < PULSE_WIDTH` 时
`sync_out = 1`，否则为 0。

> `sync_gen` 模块自身的默认参数没变；`top.v` 实例化时用自己的参数覆盖。

---

### 2.3 UART 接收器 `uart_receiver`（文件 `uart_rx.v`）

> 文件名仍是 `uart_rx.v`，但 **模块名是 `uart_receiver`**，**输入端口是 `rxd`**。
> `top.v` 中实例名 `u_uart_rx`，把外部信号 `uart_rx` 连到 `.rxd(uart_rx)`。

| 参数          | 默认值        | 说明              |
| ------------- | ------------- | ----------------- |
| `CLK_FREQ`    | 100_000_000   | 系统时钟 (Hz)     |
| `BAUD_RATE`   | 115_200       | 波特率            |

**协议**：8N1（1 起始 / 8 数据 / 无校验 / 1 停止），LSB 先出。

**实现要点：**
- 输入 `rxd` 先经过 **两级同步器**（`rx_sync0`, `rx_sync1`）规避亚稳态。
- 起始位中点（`HALF_BIT`）二次确认未变高，否则回 `S_IDLE`（毛刺过滤）。
- 数据位每 `CLKS_PER_BIT` 个时钟在中点采样，移入 `shift_reg`。
- 停止位结束时若仍为高电平，置 `rx_valid` 1 拍并输出 `rx_data`。

**数据编码约定：**

每次发送 1 字节，**低 2 bit** 有效：

| `data[1]`（基选择） | `data[0]`（bit 值） | 激活激光器 | 偏振态    |
| ------------------- | ------------------- | ---------- | --------- |
| 0                   | 0                   | `laser[0]` | 0°（H）   |
| 0                   | 1                   | `laser[1]` | 90°（V）  |
| 1                   | 0                   | `laser[2]` | +45°      |
| 1                   | 1                   | `laser[3]` | -45°      |

特殊字节 `0x71`（`'q'`）= 停止。

**输出：** `rx_data[7:0]`，`rx_valid`（单拍高电平脉冲）。

---

### 2.4 激光器控制器 `laser_ctrl.v`

| 参数                  | 默认值 | 说明                              |
| --------------------- | ------ | --------------------------------- |
| `LASER_PULSE_WIDTH`   | 10     | 激光脉冲宽度（时钟周期数）        |

| 信号        | 方向   | 说明                              |
| ----------- | ------ | --------------------------------- |
| `clk`       | input  | 系统时钟                          |
| `rst`       | input  | 同步、高有效复位                  |
| `laser_sel` | input  | 激光器选择 [1:0]（=`rx_data[1:0]`）|
| `fire`      | input  | 1 拍触发脉冲                      |
| `laser`     | output | 4 路 one-hot 激光控制 [3:0]       |
| `busy`      | output | 脉冲输出中标志                    |

**FSM（2 状态）：**

```
S_IDLE  : laser=0000, busy=0
          fire=1 → sel_latch=laser_sel, pulse_cnt=0 → S_DRIVE
S_DRIVE : 根据 sel_latch 驱动 one-hot laser, busy=1
          pulse_cnt++
          pulse_cnt == LASER_PULSE_WIDTH → laser=0, busy=0 → S_IDLE
```

> S_DRIVE 内 `fire` 被忽略——若新事件还没到 sync 沿就来了，会等当前脉冲结束。
> 主 FSM 在 `S_WAIT_SYNC` 也会阻塞下一次 `S_WAIT_RX`，所以正常时序下两层都不会
> 出现冲突。

**参数约束：** `LASER_PULSE_WIDTH < CLK_FREQ / SYNC_FREQ`
当前默认：1000 < 100_000_000 / 50_000 = 2000 ✓

---

## 3. 时序

```
uart_rx   ──[byte]──────────────────────────
                   │
top FSM            ▼ S_WAIT_SYNC
sync_out  ─┐    ┌──┐    ┌──┐
           └────┘  └────┘  └──   (20 µs 周期 @ 50 kHz)
                          │
top FSM                   ▼ fire → S_WAIT_RX
laser[i]                  ┌──┐
                          └──┘   (10 µs @ 默认参数)
laser_en                  ┌──┐
                          └──┘   (与 laser[i] 同步)
```

吞吐：UART 250 kbps ≈ 25 kbyte/s，sync 50 kHz，激光脉冲 10 µs。
每个字节最多消耗 20 µs（等待 sync）+ UART 一帧时间 40 µs ≈ 60 µs，
对应 ~16.7 kbyte/s 实际吞吐，UART 不会成为瓶颈。

---

## 4. 仿真

每个模块对应一个 testbench，位于 `user/sim/`：

| Testbench         | 测试目标                                                       | 结果 |
| ----------------- | -------------------------------------------------------------- | ---- |
| `tb_sync_gen`     | sync 周期 / 脉宽（用 `$time` 测量避免计数偏差）                 | PASS |
| `tb_uart_rx`      | 收发 0xA5/0x52/0x00/0xFF，用 `@(posedge rx_valid)` 捕获单拍脉冲 | PASS |
| `tb_uart_tx`      | 死代码模块，对应 testbench 也保留作为回归                       | PASS |
| `tb_laser_ctrl`   | 4 种 sel one-hot 编码、脉宽、busy 期间 fire 被忽略              | PASS |
| `tb_top`          | 顶层集成：4 编码触发对应激光，发 `'q'` 后无激光活动             | PASS |

详细修复记录见 `plan/sim-result.md`（所有 fail 都是 testbench 时序问题，DUT 源码未改）。

仿真用加速参数：`BAUD_RATE=10_000_000`（=100 时钟/位），`SYNC_FREQ=1 MHz`（=100 时钟/周期），
`*_PULSE_WIDTH=10`。

iverilog 编译示例：

```bash
cd FPGA-control
iverilog -o prj/icarus/tb_top.vvp \
    user/sim/tb_top.v \
    user/src/top.v user/src/sync_gen.v user/src/uart_rx.v user/src/laser_ctrl.v
vvp prj/icarus/tb_top.vvp
```

---

## 5. 文件结构

```
FPGA-control/
├── plan/
│   ├── implementation_plan.md    ← 本文件
│   ├── sim-result.md             仿真修复日志
│   ├── module.mmd / module.svg   模块层次图
│   └── circuit.tex / circuit.pdf 激光驱动电路图
├── docs/                         元件 datasheet（XC7A35T, MOC3021, …）
├── user/
│   ├── src/
│   │   ├── top.v                 顶层（含主控 FSM）
│   │   ├── sync_gen.v            同步信号发生器
│   │   ├── uart_rx.v             UART 接收器（模块名 uart_receiver）
│   │   ├── laser_ctrl.v          激光控制器
│   │   ├── data_buffer.v         ⚠ 死代码（FIFO，未被 top.v 引用）
│   │   └── uart_tx.v             ⚠ 死代码（UART 发送器，未被 top.v 引用）
│   ├── sim/
│   │   ├── tb_top.v
│   │   ├── tb_sync_gen.v
│   │   ├── tb_uart_rx.v
│   │   ├── tb_laser_ctrl.v
│   │   └── tb_uart_tx.v          ⚠ 仅为死代码 uart_tx.v 服务
│   └── data/
│       └── top.xdc               引脚约束
├── prj/
│   ├── icarus/                   iverilog 输出 .vvp
│   └── xilinx/                   Vivado 工程
└── build/                        开源工具链 (yosys + nextpnr-xilinx) 输出
```

---

## 6. 关键参数汇总（生效值）

| 参数         | 值                  | 备注                                          |
| ------------ | ------------------- | --------------------------------------------- |
| 系统时钟     | 100 MHz             | `xc7a35tfgg484-2`                             |
| 同步信号频率 | 50 kHz              | 周期 20 µs                                    |
| 同步脉宽     | 10 µs               | 1000 时钟周期                                 |
| UART 波特率  | 250 000 bps         | 与 `Alice/random-gen.py` 保持一致              |
| 激光脉宽     | 10 µs               | 1000 时钟周期，小于同步周期                    |

---

## 7. 引脚约束（`user/data/top.xdc`）

| 信号        | 物理引脚 | 说明                  |
| ----------- | -------- | --------------------- |
| `clk`       | R4       | 板载 100 MHz 时钟      |
| `rst`       | K22      | KEY3 按键              |
| `uart_rx`   | B20      | USB-UART 桥的 TX 端     |
| `sync_out`  | AA3      | TEST_A0 排针            |
| `laser[0]`  | AB3      | TEST_A1（0°/H）         |
| `laser[1]`  | AA5      | TEST_A3（90°/V）        |
| `laser[2]`  | AA6      | TEST_A5（+45°）         |
| `laser[3]`  | AB7      | TEST_A7（-45°）         |
| `laser_en`  | AB8      | TEST_A9（送 TCSPC CH）  |
| `led_empty` | V2       | 板载 LED                |

---

## 8. 协议约定

1. 上位机连续发送字节流：每字节 `data[1:0]` 编码激光器选择，其余 bit 忽略。
2. FPGA 每收 1 字节，在下一个 sync 上升沿触发一次激光脉冲。
3. UART → 触发的反压：FSM 在 `S_WAIT_SYNC` 期间忽略后续 `rx_valid`（`uart_rx`
   实际仍在继续接收，但 `S_WAIT_RX` 不在等，新字节会被覆盖）。这意味着
   **上位机不能比 sync 周期更快地发字节**，否则会丢字节。当前 BAUD 250 kbps
   ≈ 25 kBps，sync 50 kHz = 50 kBps，留有 2× 余量。
4. 收到 `0x71`（`'q'`）后 FPGA 停止，必须按 KEY3 复位才能再次工作。

---

## 9. 与初版 plan 的差异（变更日志）

为方便维护，列出已发生的偏离：

| 项                     | 初版 plan          | 实际代码                                   | 原因 |
| ---------------------- | ------------------ | ------------------------------------------ | ---- |
| `SYNC_FREQ`            | 1 MHz              | 50 kHz                                     | TCSPC + 激光器响应；同时让 250kbps UART 不会撑爆 |
| `SYNC_PULSE_WIDTH`     | 10 (100 ns)        | 1000 (10 µs)                              | TCSPC 同步输入要求较长的有效电平 |
| `BAUD_RATE`            | 115 200            | 250 000                                    | 提高吞吐；与 `Alice/random-gen.py` 一致 |
| `LASER_PULSE_WIDTH`    | 10 (100 ns)        | 1000 (10 µs)                              | 单光子事件信噪比、激光驱动电路响应 |
| `led_empty` 语义       | `state == S_STOPPED` | `dbg_rx_seen`                            | 调试用，确认 UART RX 物理通；功能性"停止灯"未保留 |
| 复位极性               | 异步低有效         | **同步、高有效**                            | 板载 KEY3 按下拉高；与 `feedback_rst_polarity` 一致 |
| UART 模块名            | `uart_rx`          | `uart_receiver`，端口 `rxd`                | 历史遗留；`top.v` 通过端口映射连接 |
| `data_buffer.v` / `uart_tx.v` | 已移除      | 仍在 `user/src/` 但不被实例化               | 死代码，未实际删除 |
| `tb_uart_tx.v`         | 未列出             | 存在并通过                                  | 服务于残留的 `uart_tx.v` |

所有 `state` 寄存器都带 `(* fsm_encoding = "none" *)`，详情见
`.claude/memory/feedback_yosys_fsm.md`（yosys 0.17 的 FSM 重编码会破坏 UART）。
