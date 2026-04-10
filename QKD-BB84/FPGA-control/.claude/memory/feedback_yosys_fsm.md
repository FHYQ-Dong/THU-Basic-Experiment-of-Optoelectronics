---
name: yosys FSM encoding bug
description: yosys 0.17 synth_xilinx FSM auto-extraction and one-hot recoding breaks uart state machines - must use fsm_encoding=none attribute
type: feedback
---

When using the open-source FPGA toolchain (yosys 0.17 + nextpnr-xilinx + prjxray), yosys's automatic FSM extraction and one-hot recoding (`synth_xilinx` includes `fsm` pass) can silently break state machines. The UART receiver FSM worked in simulation (icarus) and Vivado synthesis but failed on hardware with the open-source flow.

**Why:** yosys 0.17's FSM optimizer has bugs when recoding certain state machines to one-hot encoding, especially those with complex data path operations (dynamic bit selects, counters) coupled into the case statement.

**How to apply:** Always add `(* fsm_encoding = "none" *)` to all `state` registers in Verilog modules targeting the open-source Xilinx toolchain. This prevents yosys from extracting and recoding the FSM while keeping the rest of the synthesis flow intact.
