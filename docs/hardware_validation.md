# Hardware Validation

The accelerator was deployed on a physical Intel Cyclone 10 GX FPGA
development kit (device 10CX220YF780E5G). This document describes the
board-side wrapper, the JTAG bring-up, the on-chip self-test, and the Signal
Tap capture that confirmed the simulated latency on silicon.

## Board wrapper

`rtl/hw_top.sv` wraps `matmul_top` so that the design can be tested on a
real board with only a few real pins. The wrapper compiles into the FPGA two
fixed 4x4 INT8 test matrices (A and B) and their precomputed 4x4 INT32
product (C_EXPECTED), which were generated and confirmed against the
Python golden model. On a debounced button press, the core computes A*B on-
chip. Combinational logic then compares the hardware result against
C_EXPECTED bit for bit and asserts a pass indicator on match.

Pins used on the board:

| Signal        | Purpose                                                       |
|---------------|---------------------------------------------------------------|
| clk           | Board oscillator (routed on a dedicated clock pin)            |
| rst_n         | Reset pushbutton (active low, two-flop synchronized)          |
| btn_start     | Start pushbutton (active low, debounced)                      |
| sw_sel        | Engine select (0 = sequential, 1 = systolic)                  |
| led_pass      | On when the hardware result matches C_EXPECTED                |
| led_done      | On when a run has completed                                   |
| led_heartbeat | Approximately 1 Hz blink, confirms the board is clocked       |

The matrix interface stays internal, so the wide 768-bit data flow does not
have to be routed to real pins.

## JTAG chain bring-up

Programming over JTAG required resolving the kit's default chain
configuration before the Cyclone 10 GX FPGA appeared to the tools. On the
development kit, several on-board FMC and JTAG-isolation DIP switches gate
whether the FPGA is included in the chain and whether the on-board MAX 10
system controller drives it. With the correct switch settings, Quartus
Programmer's Auto Detect returned the 10CX220Y (IDCODE 0x02E120DD) alongside
the system MAX 10. Once detected, the .sof was programmed over the on-board
USB-Blaster II bridge.

## Result

The on-chip self-test passed on silicon. The pass LED asserted after a
button press for the systolic engine, and again with sw_sel switched to the
sequential engine, showing that both engines agree with the compiled
expected product on hardware.

A Signal Tap in-system logic-analyzer capture recorded the internal signals
`core_start`, `busy`, `core_c_flat`, and `result_pass` during a run. The
capture shows `core_start` pulsing for one cycle at sample 0, `busy`
asserted for the eleven compute cycles at samples 1 through 11 (one S_LOAD
plus ten S_FEED) and deasserting at sample 12 as the result bus settles to
the expected product, and `result_pass` asserting two cycles later at
sample 14, once the on-chip comparison stage has registered the match. The
11-cycle `busy` window reproduces the simulated systolic latency on the
running chip.

| Metric                          | Result                     | Source                    |
|---------------------------------|----------------------------|---------------------------|
| Functional self-test (systolic) | PASS                       | On-board pass indicator   |
| Functional self-test (sequential) | PASS                     | On-board pass indicator   |
| Systolic latency on silicon     | 11 cycles                  | Signal Tap capture        |
| Sequential latency              | 81 cycles                  | Simulation (tb_matmul_top)|
| Device on JTAG chain            | 10CX220Y (0x02E120DD)      | Quartus Programmer        |

## What the hardware demonstration does and does not show

The hardware run demonstrates that the RTL synthesized in Quartus, met
timing on real silicon, and produced the correct result when driven by a
button press. It does not demonstrate a full accelerator system, because
the operands and expected result are compiled into the bitstream rather
than streamed in over a bus. Adding a streaming interface (Avalon-MM or
AXI) and memory buffering is future work.
