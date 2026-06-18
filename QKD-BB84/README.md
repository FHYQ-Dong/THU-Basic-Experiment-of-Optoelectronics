# QKD-BB84

清华大学《光电子技术基础实验》自由设计实验：基于自由空间光学链路的
BB84 量子密钥分发协议端到端实现。

本仓库覆盖三个层次：

1. **FPGA 控制器**（`FPGA-control/`）—— Artix-7 上的同步信号 + UART
   + 激光器控制逻辑。
2. **Alice 主机端**（`Alice/`）—— Python 脚本：生成随机偏振串、通过 UART
   把字节流送给 FPGA、把"真值序列"存档供后续比对。
3. **后处理 / 经典纠错**（`ecc/`）—— Python 脚本：读 Bob 端的单光子事件
   CSV，执行 sifting、QBER 估算、多轮 LDPC 误码协调，得到双方一致的密钥。

物理层（激光器 + 偏振分束 + APD + TCSPC）由 FPGA 之外的光学搭建提供，
不在本仓库代码范围内。

---

## 1. 总体数据流

```
                                       Alice 主机                                           Bob 端
                                    ┌──────────────┐                                  ┌───────────────────┐
                              ┌──── │ random-gen.py │ ───→ random_data_*.txt          │ TCSPC 时间戳 CSV    │
                              │     └──────┬───────┘   (真值 0/1 + 基)                 │ + 通道编号 + match │
                              │            │                                          └─────────┬─────────┘
                              │            ▼ COM8 @ 250 kbps                                    │
                              │     ┌──────────────┐                                            │
                              │     │ FPGA 控制器   │ ─→ sync_out ───────→  TCSPC 同步输入  ←────┤
                              │     │ (FPGA-control)│ ─→ laser[3:0] ────→  4 个激光器             │
                              │     │              │ ─→ laser_en  ────→  TCSPC trigger CH       │
                              │     └──────────────┘                                            │
                              │            │                                                   │
                              │            ▼                                                   │
                              │      物理光路：偏振编码 → 自由空间 → 偏振分束 → 4 路 APD ────────┘
                              │                                                                │
                              │      ┌──────────────────────────────────────────┐              │
                              └────→ │  对齐 + sifting + match 标注（外部工具）  │ ←────────────┘
                                     └─────────────────────┬────────────────────┘
                                                           ▼
                                              ┌────────────────────────┐
                                              │ ecc/ecc_simplified.py  │ → 一致密钥 + 统计报告
                                              └────────────────────────┘
```

---

## 2. 子项目导览

### 2.1 `FPGA-control/` —— FPGA 控制层

Artix-7 (`xc7a35tfgg484-2`, 100 MHz) 上的硬件控制层。模块：

- `top.v` —— 主控 FSM：等 UART 字节 → 检查是否为 `'q'` → 等 sync 上升沿 → 触发激光。
- `sync_gen.v` —— 可调频率同步脉冲（默认 50 kHz / 10 µs 脉宽）。
- `uart_rx.v` —— 8N1 UART 接收器（默认 250 kbps）。
- `laser_ctrl.v` —— one-hot 激光器驱动（默认 10 µs 脉宽）。

完整设计与引脚约束见 [FPGA-control/README.md](FPGA-control/README.md)
与 [FPGA-control/plan/implementation_plan.md](FPGA-control/plan/implementation_plan.md)。

### 2.2 `Alice/` —— Alice 主机端

| 文件             | 作用                                                            |
| ---------------- | --------------------------------------------------------------- |
| `random-gen.py`  | 生成 0~3 的随机字节流，COM8/250 kbps 发给 FPGA，发完发 `'q'` 停机。同时把真值序列存到 `random_data_*.txt` 供 Bob 端对齐时比对。|
| `stat.py`        | 一次性脚本：从 TCSPC 文本结果里数指定通道事件数。                  |
| `temp.py`        | 一次性脚本：单光子能量、激光功率衰减系数估算。                    |

字节编码与 FPGA `laser_ctrl.v` 一致：低 2 bit = 偏振索引（0=H, 1=V, 2=+45°, 3=-45°）。

### 2.3 `ecc/` —— LDPC 误码协调

`ecc_simplified.py`：单文件 BB84 经典后处理仿真器。

输入：单光子事件 CSV（`seq,channel_mapped,txt_value,match`），其中
`channel_mapped`/`txt_value` 分别是 Alice/Bob 端通道索引，`match` 标记基匹配 (±1) 或失配 (0)。
脚本流程：

1. sifting：扔掉 `match==0` 的行；剩下的 `channel % 2` 就是双方原始密钥位。
2. 一次性构造一组 QC-LDPC 校验矩阵（多种码率）。
3. 按 N=2520 分块。对每块：估 QBER → 挑最佳码率 → 把 N 个位置划分成
   `{key, punctured, shortened}` → 归一化最小和置信传播解码。
4. 若 BP 不收敛，把最不确定的若干位"泄漏"真值，转为已知位，再跑 BP；
   最多 20 轮（multi-round disclosure 协议）。
5. 输出每块 QBER / 收敛轮数 / 信息泄漏效率，以及总体统计。

依赖：`numpy`, `scipy`, `sympy`。

```bash
cd QKD-BB84
python ecc/ecc_simplified.py path/to/events.csv [--qber 0.05] [-N 2520]
```

详细注释在 `ecc/ecc_simplified.py` 的模块级和函数级 docstring 中。

---

## 3. 环境与依赖

| 工具                | 用途                                  |
| ------------------- | ------------------------------------- |
| Python 3.12         | Alice 主机脚本 + ecc 仿真             |
| `numpy / scipy / sympy / pyserial` | 见 `pyproject.toml`     |
| Vivado              | FPGA 工程综合实现                     |
| yosys + nextpnr-xilinx + prjxray | 备选开源工具链            |
| Icarus Verilog      | 模块/集成仿真                         |
| XeLaTeX             | 报告/电路图编译（仅 plan/circuit.tex）|

Python 环境初始化：

```bash
cd QKD-BB84
uv sync   # 或者: python -m venv .venv && pip install -e .
```

---

## 4. 典型实验流程

1. **FPGA 编程**：用 Vivado 或开源工具链综合 `FPGA-control/`，烧录 `design.bit`。
2. **光学对齐**：把 FPGA 的 `sync_out` 接 TCSPC 同步、`laser_en` 接 TCSPC trigger、
   4 路 `laser[3:0]` 分别驱动对应偏振激光器。
3. **运行 Alice**：
   ```bash
   cd QKD-BB84
   python Alice/random-gen.py
   ```
   脚本会发送 `random_numbers` 字节流，发完追加 `b'q'`，FPGA 进入 `S_STOPPED`。
   真值序列同时落地为 `random_data_*.txt`。
4. **数据汇出**：从 TCSPC 软件导出事件文本，匹配 Alice 真值，生成
   `seq,channel_mapped,txt_value,match` 的 CSV。
5. **运行 ECC**：
   ```bash
   python ecc/ecc_simplified.py events.csv
   ```
   产生分块统计报告与 `events_ecc.log` 详细日志。

---

## 5. 目录结构

```
QKD-BB84/
├── README.md                    ← 本文件
├── pyproject.toml               Python 依赖
├── main.py                      占位入口（"Hello"）
├── Alice/
│   ├── random-gen.py            随机偏振串生成 + 串口发送
│   ├── stat.py                  TCSPC 通道计数小工具
│   └── temp.py                  单光子功率估算
├── FPGA-control/                Artix-7 控制器，详见其内 README
│   ├── README.md
│   ├── plan/
│   │   ├── implementation_plan.md   ← 完整设计文档
│   │   ├── sim-result.md            ← 仿真修复日志
│   │   ├── module.mmd / .svg        ← 模块层次图
│   │   └── circuit.tex / .pdf       ← 激光驱动电路图
│   ├── docs/                        元件 datasheet
│   ├── user/{src,sim,data}/         Verilog 源 / 仿真 / 约束
│   ├── prj/{icarus,xilinx}/         仿真和综合工程
│   └── build/                       开源工具链输出
└── ecc/
    └── ecc_simplified.py        LDPC 多轮误码协调（详见文件内 docstring）
```

---

## 6. 参考

- BB84 协议原始论文：Bennett & Brassard, 1984.
- 多轮 LDPC 误码协调：Elkouss et al., "Information reconciliation for QKD", 2010.
- QC-LDPC 构造（"core × QC-expand"）：参考课题组内部实现 `ldpcdecoder.py`。
- 板级文档：`FPGA-control/docs/XC7A35T_v1p1.pdf` 等。
