# 仿真结果报告

## 最终结果

| Testbench       | 最终结果 |
| --------------- | -------- |
| tb_sync_gen     | PASS     |
| tb_uart_rx      | PASS     |
| tb_uart_tx      | PASS     |
| tb_laser_ctrl   | PASS     |
| tb_top          | PASS     |

---

## 各模块详细记录

### tb_sync_gen

**初始错误：**
```
FAIL: pulse width = 3, expected 2
FAIL: period = 11, expected 10
```

**原因：** testbench 用 `@(posedge sync_out)` 对齐后立即进入 `while (sync_out) @(posedge clk)` 计数。`sync_out` 是组合逻辑，在 `posedge clk` 后由 `cnt` 驱动更新。while 循环里每次先等时钟沿、再检查 `sync_out`，导致第一次循环已经计入了对齐时的那个时钟沿，高电平和周期各多计1。

**修复方法：** 改用 `$time` 时间戳测量。在 `@(posedge sync_out)` → `@(negedge sync_out)` → `@(posedge sync_out)` 三个事件之间记录时间差，除以时钟周期得到精确的脉冲宽度和周期，完全避免计数偏差。

---

### tb_uart_rx

**初始错误：**
```
FAIL: expected 0xA5, got 0xa5 (valid=0)
FAIL: expected 0x52, got 0x52 (valid=0)
...
```
数据值正确，但 `rx_valid` 始终为0。

**原因：** `send_byte` 任务在停止位结束时（`repeat(CLKS_PER_BIT) @(posedge clk)` 之后）返回，但 `rx_valid` 实际上在停止位采样的那个时钟沿就已经拉高又归零了——比 `send_byte` 返回早1拍。testbench 在 `send_byte` 返回后才检查，永远错过了这个单周期脉冲。

**修复方法：**
1. `send_byte` 改为不等停止位完成即返回（驱动 `uart_rx_in=1` 后直接返回）。
2. 检查逻辑改为 `@(posedge rx_valid)` 事件等待，而不是固定等若干拍后采样。

---

### tb_uart_tx

**初始错误：** 仿真卡死（超时）。

**原因（两处）：**

1. `tx_start` 在 `@(posedge clk)` 之前赋值（阻塞赋值无延迟），DUT 在同一拍采样到 `tx_start=1` 并立即进入 S_START，`uart_tx` 在下一拍变低。而 testbench 在 `tx_start` 脉冲之后才调用 `recv_byte`，此时 `uart_tx` 已经变低，`@(negedge uart_tx_out)` 等不到下降沿，死锁。

2. Test 3 中第二次 `tx_start` 脉冲发生在 DUT 忙碌期间（被正确忽略），但 `recv_byte` 仍在等第二个下降沿，导致死锁。

**修复方法：**
1. 将 `tx_start` 赋值改为 `@(posedge clk); #1 tx_start=1`，在时钟沿后1ps赋值，避免与 DUT 采样竞争。
2. 用 `fork/join` 并行启动 `recv_byte`（等下降沿）和 `tx_start` 脉冲，确保监听在发送触发之前就已就绪。
3. `recv_byte` 的停止位等待从 `CLKS_PER_BIT` 改为 `CLKS_PER_BIT * 2`，给 DUT 足够时间回到 S_IDLE 再检查 `tx_busy`。

---

### tb_laser_ctrl

**初始错误：**
```
FAIL slot 0: expected laser=0001, got 0000
...
```

**原因（三处）：**

1. **`sync_rise` 永远为0：** `sync_pulse` 任务用 `sync_in = 1`（无延迟阻塞赋值），在 `@(posedge clk)` 之前执行，时钟沿到来时 `sync_in` 和 `sync_prev` 都已经是1，`sync_rise = sync_in & ~sync_prev` 永远为0，DUT 从未检测到上升沿。

2. **检查时序偏早：** trigger 发生后，DUT 需要经过 IDLE→READ（+1拍）→DRIVE（+2拍）→laser 寄存器稳定（+3拍），共需在 trigger 后等4拍才能采样到稳定的 laser 输出。原 testbench 只等了2~3拍。

3. **FIFO 模拟数据偏移：** `fifo_data` 和 `fifo_empty` 用非阻塞赋值，但 `fifo_head` 用阻塞赋值，同一 `always` 块内混用导致 `fifo_queue[fifo_head]` 索引与数据更新不同步，读出的数据比预期偏移1条。

**修复方法：**
1. `sync_pulse` 改为 `@(posedge clk); #1 sync_in = 1`，在时钟沿后1ps赋值，确保 DUT 在下一个时钟沿能检测到上升沿。
2. 重构为 `fire_slot(extra_wait)` 任务，在 trigger 上升沿后等指定拍数再返回，检查时等4拍。
3. FIFO 模拟改为：用 `rd_en_r` 打一拍延迟，在 `rd_en` 拉高后的下一拍才更新 `fifo_data`，模拟真实 FIFO 的读延迟；所有赋值改为阻塞赋值保持一致性。

---

### tb_top

**初始错误：**
```
FAIL: timeout waiting for TX notification
```

**原因：** testbench 先等 FIFO 耗尽（Step 3），再开始调用 `uart_recv` 等 TX 通知（Step 4）。但 TX 通知在 FIFO 耗尽的瞬间就已发出，`uart_recv` 的 `@(negedge uart_tx_out)` 错过了下降沿，永远等不到。

**修复方法：** 用 `fork/join` 并行启动 `uart_recv`（监听下降沿）和主流程（发送数据、等待耗尽），确保监听器在 FIFO 耗尽之前就已就绪，不会错过 TX 通知。

---

## 根因总结

所有错误均为 **testbench 时序问题**，DUT 源代码逻辑正确，无需修改。

| 类型 | 具体问题 | 涉及模块 |
| ---- | -------- | -------- |
| 计数偏差 | while 循环计数多1 | tb_sync_gen |
| 单周期脉冲错过 | 固定等待拍数不足，错过1周期有效信号 | tb_uart_rx、tb_uart_tx |
| 竞争冒险 | 阻塞赋值无延迟，与 DUT 时钟沿竞争 | tb_uart_tx、tb_laser_ctrl |
| 事件错过 | 监听器启动晚于事件发生 | tb_uart_tx、tb_top |
| FIFO 模拟时序 | 混用阻塞/非阻塞赋值导致数据偏移 | tb_laser_ctrl |
