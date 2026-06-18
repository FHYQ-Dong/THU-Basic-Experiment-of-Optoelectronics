# QKD-BB84 FPGA 控制器

Artix-7 (`xc7a35tfgg484-2`, 100 MHz) 上的 BB84 协议硬件控制层。
负责产生 TCSPC 同步信号、通过 UART 接收 Alice 主机的随机偏振指令、
并在每个同步沿触发一路对应的激光器，发射单光子脉冲。

> 设计与文件结构的全部细节在 [plan/implementation_plan.md](plan/implementation_plan.md)；
> 本 README 是顶层导航。

---

## 1. 数据流速览

```
PC (Alice/random-gen.py) ──UART──> uart_receiver ──┐
                                                   ▼
                                  ┌────────── top.v 主 FSM ────────┐
                                  │  S_WAIT_RX → S_CHECK_Q          │
sync_gen ─sync_out─┬──┐           │  → S_WAIT_SYNC → S_WAIT_RX       │
                   │  └──fire──>  │  (收到 'q' 0x71 → S_STOPPED)      │
                   ▼              └─┬────────────────────────────────┘
              TCSPC 同步输入       │ laser_sel[1:0] = rx_data[1:0]
                                   ▼
                              laser_ctrl ──┬─> laser[3:0]  → 4 激光器
                                           └─> laser_en    → TCSPC trigger CH
```

`laser_sel[1:0]` ↔ 偏振态：`00`=H(0°), `01`=V(90°), `10`=+45°, `11`=-45°。

---

## 2. 模块清单

| 文件                | 模块           | 作用                                                | 备注 |
| ------------------- | -------------- | --------------------------------------------------- | ---- |
| `user/src/top.v`         | `top`            | 顶层，主控 FSM，sync 上升沿检测                   | 默认 50 kHz sync / 250 kbps UART |
| `user/src/sync_gen.v`    | `sync_gen`       | 分频器，产生可调频率的同步脉冲                    | — |
| `user/src/uart_rx.v`     | `uart_receiver`  | 8N1 UART 接收，含两级同步器                       | 端口 `rxd`，输出单拍 `rx_valid` |
| `user/src/laser_ctrl.v`  | `laser_ctrl`    | 接 `fire` 触发，输出 one-hot 固定宽度激光脉冲     | 2 状态 FSM |
| `user/src/data_buffer.v` | `data_buffer`    | ⚠ 死代码：FIFO，未被 `top.v` 引用                  | 早期方案残留 |
| `user/src/uart_tx.v`     | `uart_tx`        | ⚠ 死代码：UART 发送器，未被 `top.v` 引用            | 早期方案残留（时间戳回传方案） |

> 死代码模块可以删，也可以留——`top.v` 不实例化，不会进入综合结果。

---

## 3. 关键参数（`top.v` 默认值）

| 参数                  | 默认值       | 物理含义                       |
| --------------------- | ------------ | ------------------------------ |
| `CLK_FREQ`            | 100 MHz      | 板载晶振                       |
| `SYNC_FREQ`           | 50 kHz       | TCSPC 同步周期 20 µs           |
| `SYNC_PULSE_WIDTH`    | 1000 (10 µs) | 同步脉冲高电平时间             |
| `BAUD_RATE`           | 250 000      | 与 `Alice/random-gen.py` 一致 |
| `LASER_PULSE_WIDTH`   | 1000 (10 µs) | 激光脉冲宽度                   |

约束：`LASER_PULSE_WIDTH < CLK_FREQ / SYNC_FREQ`（10 µs < 20 µs ✓）。

---

## 4. 引脚映射（`user/data/top.xdc`）

| 信号        | FPGA pin | 板上                  |
| ----------- | -------- | --------------------- |
| `clk`       | R4       | 100 MHz osc           |
| `rst`       | K22      | KEY3（按下=复位）      |
| `uart_rx`   | B20      | USB-UART RX           |
| `sync_out`  | AA3      | TEST_A0 → TCSPC SYNC  |
| `laser[0]`  | AB3      | TEST_A1 → 0° 激光     |
| `laser[1]`  | AA5      | TEST_A3 → 90° 激光    |
| `laser[2]`  | AA6      | TEST_A5 → +45° 激光   |
| `laser[3]`  | AB7      | TEST_A7 → -45° 激光   |
| `laser_en`  | AB8      | TEST_A9 → TCSPC trig  |
| `led_empty` | V2       | 板载 LED（调试指示）   |

---

## 5. 构建与仿真

### 5.1 Icarus Verilog 仿真

```bash
cd FPGA-control

# 顶层集成 testbench
iverilog -o prj/icarus/tb_top.vvp \
    user/sim/tb_top.v \
    user/src/top.v user/src/sync_gen.v user/src/uart_rx.v user/src/laser_ctrl.v
vvp prj/icarus/tb_top.vvp

# 单模块 testbench
iverilog -o prj/icarus/tb_sync_gen.vvp   user/sim/tb_sync_gen.v   user/src/sync_gen.v
iverilog -o prj/icarus/tb_uart_rx.vvp    user/sim/tb_uart_rx.v    user/src/uart_rx.v
iverilog -o prj/icarus/tb_laser_ctrl.vvp user/sim/tb_laser_ctrl.v user/src/laser_ctrl.v
```

仿真预期：每个 testbench 在末尾打印 `PASS: ... all checks passed`。
失败排查见 [plan/sim-result.md](plan/sim-result.md)。

### 5.2 Vivado 综合实现

工程目录 `prj/xilinx/`，约束 `user/data/top.xdc`。

### 5.3 开源工具链（yosys + nextpnr-xilinx + prjxray）

输出在 `build/` 下（`design.bit`, `design.fasm`, …）。
**注意**：所有 `state` 寄存器必须保留 `(* fsm_encoding = "none" *)`
属性，否则 yosys 0.17 的 FSM 重编码会破坏 UART 接收。
详情见 [.claude/memory/feedback_yosys_fsm.md](.claude/memory/feedback_yosys_fsm.md)。

---

## 6. 协议（FPGA ↔ Alice 主机）

1. Alice 主机连续发送字节流，每字节 `data[1:0]` 选偏振，其余 bit 忽略。
2. FPGA 每收 1 字节，等下一个 sync 上升沿，触发对应激光器一次脉冲。
3. **吞吐限制**：FSM 在 `S_WAIT_SYNC` 期间不接收新字节。上位机发字节速率
   必须 ≤ sync 频率（50 kHz），250 kbps UART ≈ 25 kBps 满足。
4. 收到 `0x71`（`'q'`）→ 进入 `S_STOPPED`，必须复位才能再次工作。

---

## 7. 复位约定

所有模块统一使用 **同步、高有效**复位：`if (rst) ...`。
testbench 也应该 `rst=1` → 等几个 clk → `rst=0`。
板载 KEY3 按下时拉高 `rst`。

---

## 8. 已知偏离 / 调试遗留

- `led_empty` 当前是"收到任意字节常亮"的调试指示，不是初版 plan 中的
  "停止灯"。要恢复语义：将 `top.v` 末尾的 `assign led_empty = dbg_rx_seen;`
  换回 `assign led_empty = (state == S_STOPPED);` 即可。
- UART 模块名是 `uart_receiver`（不是 `uart_rx`），端口名 `rxd`（不是 `uart_rx`），
  但文件名仍叫 `uart_rx.v`。`top.v` 中通过端口映射连接。
- `data_buffer.v`/`uart_tx.v` 是早期 FIFO + 时间戳回传方案的遗物，不影响
  当前综合。

---

## 9. 相关文档

- [plan/implementation_plan.md](plan/implementation_plan.md) — 完整设计文档
- [plan/sim-result.md](plan/sim-result.md) — 仿真修复日志（DUT 无 bug，全是 testbench 时序问题）
- [plan/circuit.tex](plan/circuit.tex) / `plan/circuit.pdf` — 激光驱动外围电路图
- [plan/module.mmd](plan/module.mmd) / `plan/module.svg` — 模块层次图
- `docs/` — 元件 datasheet：XC7A35T、MOC3021、BTB06、2N7000、LF353
- [.claude/memory/feedback_rst_polarity.md](.claude/memory/feedback_rst_polarity.md)
- [.claude/memory/feedback_yosys_fsm.md](.claude/memory/feedback_yosys_fsm.md)
