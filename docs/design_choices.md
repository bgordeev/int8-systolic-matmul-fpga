# Design Choices

Every design is a set of forks. This document lists the main choices made in
the project and, for each, the alternative and the reason for the choice. It
is intended as a reference for anyone reviewing the design or asking why
things were done a particular way.

## INT8 multiply with INT32 accumulate

Chosen over narrower or wider accumulation. An INT8 x INT8 product needs 16
bits, and summing K products needs 16 + ceil(log2(K)) bits. A 32-bit
accumulator is safe for K up to 2^16 terms and matches common bus widths. The
wide accumulator makes overflow impossible for the sizes tested, which
removes saturation logic and a whole class of silent bugs. See
[int8_quantization.md](int8_quantization.md).

## Output-stationary dataflow

Chosen over weight-stationary and input-stationary. The output partial sums
are the widest values (32 bits) and stay in place. Only the 8-bit operands
travel between PEs, which keeps wiring local and the critical path short.
Weight-stationary and input-stationary alternatives move the wide partial
sums between PEs, at a higher wiring cost. Output-stationary is also the
simplest to reason about and verify.

## Skew logic in the controller, not the array

Chosen over embedding cycle-count awareness in each PE. The array stays a
pure, reusable mesh with no notion of timing. A single wrapper
(`matmul_controller.sv`) handles the row-i and column-j delays and the 3N-2
feed schedule. This separation makes the array trivially parameterizable in
N and the controller the only place timing logic lives.

## Two engines behind one runtime multiplexer

Chosen over building the systolic engine alone. Putting both engines in
`matmul_top` lets a single testbench run identical stimuli through both and
demand bit-exact agreement (the engine cross-check in
`tb_matmul_top.sv`). That check catches bugs neither testbench alone would
find, and it makes the reported 7.4x speedup an apples-to-apples comparison
on the same operands.

## Flat packed result buses

Chosen over unpacked 2-D output-array ports. Unpacked-array output ports do
not propagate portably across all simulators (Icarus in particular has
known issues). Row-major flat buses of width N*N*ACC_WIDTH bits, with
generate-block packing and unpacking at the boundaries, are the portable
idiom and cost no logic because the indices are compile-time constants.
Unpacked-array input ports are used freely.

## Virtual pins for synthesis characterization

Chosen over inventing a fake pinout. The 768-bit matrix interface
does not fit on package pins on any real board. Virtual pins let the Fitter
treat the data ports as internal nets, giving honest area and Fmax numbers
for the core that will eventually sit behind a memory-mapped bus. This is
standard practice for compute-core characterization.

## A separate hardware wrapper (hw_top.sv)

Chosen over trying to expose the full matrix interface on real pins. Rather
than route 768 bits of data through real I/O, `hw_top.sv` compiles two fixed
INT8 test matrices and their known product into the FPGA, exposes only a
button and a pass LED, and compares the hardware result against the
expected value on-chip. This is what makes an in-system demonstration
possible without a memory interface, which is future work.

## Level-held done, separate from busy

Chosen over a single pulsed status line or a pulsed done. The done signal
stays high until the next start so a slow downstream consumer cannot miss
it, and busy and done are kept distinct so that during idle the engine is
neither busy nor done. A single status line would be ambiguous during idle
and would create integration bugs.

## Seeded and magnitude-bounded random tests

Chosen over unbounded random operands. The Python generator uses a fixed
seed so results are reproducible, and bounds operand magnitude so
accumulators are provably inside the 32-bit range during random tests.
Directed tests cover zero, identity, and signed cases separately, so the
random tests exercise coverage without racing overflow.

## Python golden model, independent verifier

Chosen over verifying only through simulation self-checks. The Python
model (`scripts/generate_vectors.py`) is written independently of the RTL
and produces both A, B, and the expected C. A separate script
(`scripts/verify_results.py`) then re-checks the simulator's output file
against the model. Independence of the checker from the design being
checked is what makes the verification meaningful, and it is why the
accompanying paper calls the flow "layered" rather than merely
"self-checking."

## Single hardware demonstration case

Chosen over an interactive input path on the board. The wrapper runs one
compiled-in test case rather than accepting arbitrary matrices, because
the point of the physical demonstration is to prove the design runs on
silicon and matches simulation, not to build a general accelerator. Adding
streaming inputs is future work and is called out as such.
