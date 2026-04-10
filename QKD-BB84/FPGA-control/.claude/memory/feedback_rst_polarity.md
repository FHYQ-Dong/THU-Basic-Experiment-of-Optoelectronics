---
name: Reset polarity convention
description: This project uses active-HIGH synchronous reset (rst=1 means reset) for all FPGA modules
type: feedback
---

All FPGA modules in the QKD-BB84 project use active-HIGH synchronous reset: `if (rst)` resets the module. Testbenches should initialize `rst=1`, wait a few clocks, then deassert with `rst=0`.

**Why:** The board's reset button (K22) drives rst high when pressed. The convention was confirmed by the user.

**How to apply:** When writing new modules or testbenches, always use `rst=1` for reset, `rst=0` for normal operation.
