# Project Summary and Technical Q&A

This document summarizes the project and answers the technical questions most
likely to come up in a review. It complements the technical
report.

## Brief summary

This is a parameterized INT8 matrix-multiply accelerator in SystemVerilog,
built for the Intel Cyclone 10 GX. It contains two architectures: a
sequential single-MAC baseline and a 4x4 output-stationary systolic array.
Both are verified bit-for-bit against a Python golden model. The systolic
version completes a 4x4 multiply in 11 cycles versus 81 for the baseline, a
7.4x cycle-count speedup, and the ALM, DSP, and Fmax tradeoffs are
characterized in Quartus.

## Extended summary

1. Problem. Matrix multiplication is a major compute kernel in machine-
   learning inference, and inference hardware commonly runs it in INT8 with
   INT32 accumulation. This project builds that datapath.

2. What it contains. Two architectures behind one interface. The baseline is
   an FSM with a single shared MAC, taking 1 + N^3 + N^2 cycles, which is 81
   for N = 4. The accelerator is an output-stationary systolic array with one
   processing element per output element. A streams east, B streams south,
   and a controller skews the inputs so that A[i][k] and B[k][j] meet at
   PE(i,j) on the same cycle. It completes in 3N-2 feed cycles, 11 in total,
   a 7.4x speedup using N^2 = 16 multipliers instead of one.

3. Verification. The flow is simulation-first: unit tests on the raw array
   with testbench-generated skew, integration tests through the top level,
   directed cases for signed and zero values, identity matrices, random vectors, hex
   vectors from a Python golden model, and an independent Python check on
   the simulator output. The two engines are also cross-checked against each
   other on identical inputs.

4. Measurement. The core is synthesized for the Cyclone 10 GX with virtual
   pins. DSP usage scales with the square of the array dimension, which is
   the central resource-versus-latency tradeoff analyzed in the report.

5. Hardware validation. The core was deployed on a physical Cyclone 10 GX
   development kit. An on-chip self-test asserted the pass indicator on
   silicon, and a Signal Tap capture confirmed the 11-cycle systolic
   latency on hardware.

6. Next steps. An Avalon or AXI streaming interface, double buffering, and
   requantization so that the accelerator can run a complete quantized
   layer.

## Technical questions and answers

Why output-stationary? The partial sums, which are the widest values at 32
bits, never move. Only the 8-bit operands travel between PEs.
Weight-stationary and input-stationary dataflows move partial sums between
PEs instead, at a higher wiring cost.

Derivation of the skew. An A value injected at the west reaches column j
after j hops. A B value injected at the north reaches row i after i hops.
Injecting A[i][k] at t = k+i and B[k][j] at t = k+j makes both arrive at
PE(i,j) at t = k+i+j, which yields the 3N-2 cycle bound for the feed phase.

Why is ACC_WIDTH 32? One product needs 16 bits, and a K-term sum needs
16 + ceil(log2(K)) bits, so 32 bits covers K up to 2^16. If the accumulator
were narrowed, the design would need to choose between saturation and wrap-
around on overflow.

What is the critical path? It is read from the Quartus Timing Analyzer.
Likely candidates are the 32-bit accumulator add inside a PE or the skew
multiplexer feeding the array edges.

How does this differ from a production accelerator? The simplifications are
parallel matrix ports rather than a bus with SRAM buffering, no
requantization, no tiling for matrices larger than the array, and a single
matrix multiply at a time.

What happens at 64x64? The limiting factors become I/O and buffering rather
than the PE array. A large multiply would be tiled into array-sized blocks,
with tiles streamed from M20K or DDR.


