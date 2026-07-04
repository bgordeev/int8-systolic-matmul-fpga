# Parameterized INT8 Systolic Matrix-Multiply Accelerator (Intel Cyclone 10 GX)

A simulation-verified FPGA project in SystemVerilog containing two hardware
matrix-multiply engines (a sequential MAC baseline and an N x N systolic
array), self-checking testbenches, a Python golden model, a Quartus synthesis
flow, and a technical report.

Verified simulation results (Icarus Verilog, N = 4, INT8 operands, 32-bit
accumulators):

| Engine            | Total cycles | Result                                    |
|-------------------|--------------|-------------------------------------------|
| V1 Sequential MAC | 81           | All tests pass.                           |
| V2 Systolic array | 11           | All tests pass, bit-exact match with V1.  |
| Cycle speedup     | 7.4x         |                                           |

Post-fit synthesis (Quartus Prime Pro 26.1, 10CX220YF780E5G, 100 MHz constraint):

| Design            | ALMs  | DSP | Restricted Fmax |
|-------------------|-------|-----|-----------------|
| V1 Sequential MAC | 506   | 1   | 162.6 MHz       |
| V2 Systolic array | 822   | 16  | 165.8 MHz       |
| Combined top      | 1,220 | 17  | 163.2 MHz       |

## Overview

The project implements custom hardware that multiplies two 4x4 matrices of
signed 8-bit integers and produces a 4x4 matrix of 32-bit results. It does so
with two different architectures. Version 1 (baseline) uses a single multiplier
that performs all 64 multiplications one at a time, sequenced by a finite state
machine. Version 2 (accelerator) uses a 4x4 grid of 16 multiply-accumulate
units, a systolic array, through which the matrices stream, with all 16 units
operating in parallel each cycle. Both engines produce bit-identical results,
verified automatically against a Python reference model.

Matrix multiplication is a major compute kernel in neural-network inference,
and dedicated accelerators such as the Google TPU and GPU tensor cores are, at
their core, large grids of multiply-accumulate units. This project is a
small-scale implementation of that idea in signed 8-bit integer arithmetic
(INT8), which reduces multiplier area and memory bandwidth relative to floating
point at the cost of small accuracy loss when the network is calibrated for low
precision. For background see [docs/int8_quantization.md](docs/int8_quantization.md),
and for the design itself see [docs/architecture.md](docs/architecture.md).

## What is in the repository

The technical report ([report/report.pdf](report/report.pdf)) is the primary
document and covers design, verification, synthesis, and hardware validation in
depth.

```
fpga-int8-matmul-accelerator/
|-- README.md
|-- report/
|   \-- report.pdf                  technical report
|-- rtl/
|   |-- matmul_pkg.sv               shared parameters and accumulator-width math
|   |-- pe_mac.sv                   single signed multiply-accumulate unit
|   |-- sequential_matmul.sv        V1: FSM plus one MAC (81 cycles at N = 4)
|   |-- systolic_pe.sv              output-stationary processing element
|   |-- systolic_array.sv           N x N generate-based PE mesh
|   |-- matmul_controller.sv        V2: skew generator plus FSM (11 cycles at N = 4)
|   \-- matmul_top.sv               both engines plus runtime select mux
|-- tb/                             self-checking testbenches
|-- scripts/                        golden model, verifier, quantization demo
|-- vectors/                        generated hex test vectors
|-- quartus/                        project TCL and SDC constraints
\-- docs/                           extended documentation 
```

## Running the Python golden model

Requires only Python 3.

```bash
cd fpga-int8-matmul-accelerator
python3 scripts/generate_vectors.py         # defaults: N = 4, |values| <= 16, seed 2026
# options: python3 scripts/generate_vectors.py --size 4 --max-mag 16 --seed 123
```

This prints A, B, and C = A x B and writes two's-complement hex files to
vectors/ (A_matrix.hex, B_matrix.hex, C_expected.hex), which the testbenches
read with `$readmemh`.

## Running the simulation

Any SystemVerilog-2012 simulator works. With Icarus Verilog
(`apt install iverilog`, or `brew install icarus-verilog`), run from the project
root so the vectors/ paths resolve:

```bash
# V1 sequential baseline (5 tests)
iverilog -g2012 -o sim_seq rtl/*.sv tb/tb_sequential_matmul.sv && vvp sim_seq

# V2 systolic array (7 tests including identity)
iverilog -g2012 -o sim_arr rtl/*.sv tb/tb_systolic_array.sv && vvp sim_arr

# Top level: both engines on identical inputs, cross-check, and latency
# measurement (14 tests). Writes vectors/C_hw_out.hex.
iverilog -g2012 -o sim_top rtl/*.sv tb/tb_matmul_top.sv && vvp sim_top
```

Each testbench is self-checking and ends with a pass or fail summary, and dumps
a .vcd waveform viewable in GTKWave. With Questa or ModelSim, compile the same
file lists (`vlog -sv rtl/*.sv tb/<tb>.sv` then `vsim -c <tb> -do "run -all"`).

Then independently re-verify the hardware output with Python:

```bash
python3 scripts/verify_results.py           # compares vectors/C_hw_out.hex against the golden model
```

## Synthesizing in Quartus

Quartus Prime Pro is required because the Cyclone 10 GX is a Pro-edition
device. From the project root:

```bash
cd quartus
quartus_sh -t create_project.tcl
```

This creates a project targeting part 10CX220YF780E5G (the Cyclone 10 GX
development-kit device), adds the RTL, applies constraints.sdc (a 100 MHz
clock), and assigns virtual pins to the wide data ports so the design compiles
standalone without board-specific pins. Then run a full compile:

```bash
quartus_sh --flow compile int8_matmul
```

To compare the two engines, compile twice with the top-level entity set to
`sequential_matmul` and then to `matmul_controller`. Real pin assignments for a
physical board must come from the official board schematic or pin table.

Post-fit numbers are read from the Compilation Report. Resource usage (ALMs,
registers, DSP blocks, M20K) appears under Fitter, Resource Section, Resource
Usage Summary. Restricted Fmax and slack appear under the Timing Analyzer at
the slow corner. Full detail is in the report.

## Collecting results

- Total cycles: measured by `tb_matmul_top.sv` (81 versus 11 for N = 4).
- Operations: 2N^3 (128 for N = 4).
- GOPS estimate: 2N^3 x Fmax / total_cycles / 10^9. This is a core-level peak
  estimate that assumes operands are already on-chip and does not account for
  memory bandwidth.

## Scope and limitations

This project covers design, simulation, synthesis, and in-system validation of
the compute core.

- Operands and results move through wide parallel ports, characterized in
  Quartus with virtual pins. A deployable accelerator would stream data over a
  memory-mapped bus (Avalon-MM or AXI) into on-chip buffers.
- Matrix size is fixed at build time. There is no run-time tiling for larger
  matrices.
- Throughput figures describe the compute core and do not model memory
  bandwidth.
- The datapath computes an integer GEMM. Requantization (INT32 back to INT8
  between layers) is not implemented.

For rationale behind these and other choices see
[docs/design_choices.md](docs/design_choices.md).

## Future extensions

- Larger arrays (8x8, 16x16) with a scaling study of Fmax and area
- On-chip M20K double buffering to overlap operand load with compute
- An Avalon-MM or AXI4-Lite slave interface
- DDR streaming with temporal tiling
- Mapping a CNN convolution layer via im2col
- End-to-end INT8 quantized inference with measured accuracy
- Integration with a RISC-V soft core as a memory-mapped coprocessor
- Hardware performance counters
- A weight-stationary dataflow comparison

## Documentation

Extended documentation lives in [docs/](docs/). Start with
[docs/architecture.md](docs/architecture.md) for the design itself, or with
[docs/project_summary.md](docs/project_summary.md) for an overview and
technical Q&A.

## License

MIT. See LICENSE.
