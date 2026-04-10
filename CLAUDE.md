# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

THU optoelectronics course (光电子技术基础实验) lab reports and code. Each `Exp<N>/` directory is a standalone experiment with docs, images, and optional scripts/reports. The `QKD-BB84/` directory is a BB84 quantum key distribution project with both Python host code and FPGA Verilog firmware.

## Repository Structure

- **Exp1** – Electro-optic modulation & voice signal transmission (images/docs only)
- **Exp3** – Semiconductor laser characterization (LaTeX report + Python plotting scripts)
- **Exp4** – WDM fiber transmission system (data/images/docs only)
- **Exp5** – Holographic grating (docs only)
- **QKD-BB84/** – BB84 protocol implementation
  - `Alice/random-gen.py` – Host-side random polarization generator, sends bytes over serial (COM port, 115200 baud)
  - `FPGA-control/` – Verilog firmware for Artix-7 FPGA (xc7a35tfgg484-2, 100MHz). Has its own `.claude/CLAUDE.md` with detailed FPGA context
  - `.python-version` specifies Python 3.12; venv in `.venv/`

## Build & Run Commands

### LaTeX Reports (Exp3)
```bash
cd Exp3
# Requires XeLaTeX + ctex for Chinese support
latexmk -xelatex Exp3-report.tex -outdir=build
```

### Python Scripts (Exp3)
```bash
cd Exp3/scripts
python P-I-curve.py    # Plot P-I curve with linear fit
python P-T-curve.py    # Plot P-T curve
python dbm2mW.py       # dBm to mW conversion utility
```
Dependencies: `numpy`, `matplotlib`

### QKD-BB84 Python (Alice host)
```bash
cd QKD-BB84
# Uses Python 3.12, pyserial
python Alice/random-gen.py   # Sends random polarization bytes to FPGA via serial
```

### QKD-BB84 FPGA Simulation (Icarus Verilog)
```bash
cd QKD-BB84/FPGA-control
# Compile and run individual testbenches
iverilog -o prj/icarus/tb_top.vvp user/sim/tb_top.v user/src/top.v user/src/sync_gen.v user/src/uart_rx.v user/src/laser_ctrl.v
vvp prj/icarus/tb_top.vvp

# Individual module tests
iverilog -o prj/icarus/tb_sync_gen.vvp user/sim/tb_sync_gen.v user/src/sync_gen.v
iverilog -o prj/icarus/tb_uart_rx.vvp user/sim/tb_uart_rx.v user/src/uart_rx.v
iverilog -o prj/icarus/tb_laser_ctrl.vvp user/sim/tb_laser_ctrl.v user/src/laser_ctrl.v
```

### QKD-BB84 FPGA Synthesis (Vivado)
Xilinx Vivado project in `QKD-BB84/FPGA-control/prj/xilinx/`. Constraints in `user/data/top.xdc`.

## Key Architecture: QKD-BB84 FPGA

The FPGA firmware uses a simple 4-state FSM in `top.v`:
1. **S_WAIT_RX** – Wait for UART byte from Alice
2. **S_CHECK_Q** – If byte is `0x71` ('q'), stop; otherwise proceed
3. **S_WAIT_SYNC** – Wait for sync rising edge, then fire the selected laser
4. **S_STOPPED** – Halted until reset

Submodules: `sync_gen.v` (configurable-frequency sync pulse), `uart_rx.v` (8N1 UART receiver), `laser_ctrl.v` (one-hot laser pulse driver). Data encoding: byte low 2 bits select which of 4 lasers (polarization states H/V/+45/-45).

## Conventions

- Reports are in Chinese (LaTeX with `ctex`)
- Git LFS tracks `*.pdf`, `*.png`, `*.jpg` (see `.gitattributes`)
- `.gitignore` excludes `build/` directories
- The FPGA subproject has its own `.gitignore` excluding Vivado project files
