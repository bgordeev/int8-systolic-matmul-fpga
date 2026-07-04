# Architecture

## The problem being accelerated

Matrix multiplication, C = A x B, is a major compute kernel in deep-learning
inference. Fully connected layers are matrix multiplies, convolutions are
commonly lowered to matrix multiplies through im2col, and attention is a
sequence of them. For N x N matrices the work is N^3 multiply-accumulate (MAC)
operations, which is 64 MACs for N = 4.

Both versions in this project compute the same function bit-for-bit. They
differ in how many MACs are performed per cycle.

## Parameters

All sizes are set by parameters in `matmul_pkg.sv` rather than hardcoded, so
the same source runs at any square N after re-elaboration.

| Parameter    | Default | Meaning                                          |
|--------------|---------|--------------------------------------------------|
| DATA_WIDTH   | 8       | Operand width (signed INT8)                      |
| ACC_WIDTH    | 32      | Accumulator and result width (signed INT32)      |
| MATRIX_SIZE  | 4       | Square matrix dimension N                        |
| ARRAY_N      | 4       | Systolic-array dimension, matched to MATRIX_SIZE |

The generate loops in `systolic_array.sv` produce ARRAY_N^2 processing
elements, the FSM counters in `sequential_matmul.sv` size themselves to
ceil(log2(N)) bits, and the skew logic in `matmul_controller.sv` uses N
throughout. Only N = 4 was measured in the results, but the RTL is written for
general N.

## Version 1: sequential baseline (sequential_matmul.sv)

A single shared MAC computes one product per cycle, driven by an FSM that
advances three nested loop counters (i, j, k) held in registers:

```
for i: for j: { acc = 0; for k: acc += A[i][k]*B[k][j]; C[i][j] = acc; }
```

- Latency: 1 (INIT) + N^3 (COMPUTE) + N^2 (STORE) cycles
  = 1 + 64 + 16 = 81 cycles for N = 4.
- Resources: one multiplier (about one DSP block), a few counters, the input
  registers, and N^2 output registers.
- Purpose: it is simple to verify. It serves as the golden hardware reference
  and as the denominator for the speedup comparison.

## Version 2: output-stationary systolic array (systolic_array.sv and matmul_controller.sv)

An N x N grid of processing elements (PEs). PE(i,j) owns output element
C[i][j]. It is the output-stationary dataflow used by the Google TPU:

```
         B[*][0]  B[*][1]  B[*][2]   B[*][3]     (columns of B enter from the north)
            |        |        |         |
            v        v        v         v
A[0][*] -> PE00 ->  PE01 ->  PE02  ->  PE03
A[1][*] -> PE10 ->  PE11 ->  PE12  ->  PE13      (rows of A enter from the west)
A[2][*] -> PE20 ->  PE21 ->  PE22  ->  PE23
A[3][*] -> PE30 ->  PE31 ->  PE32  ->  PE33
```

Each cycle, every PE performs three actions. It multiplies the A value
arriving from the west by the B value arriving from the north and adds the
product to a local accumulator, forwards A one hop east, and forwards B one
hop south.

### Why the data is skewed

PE(i,j) needs the pair (A[i][k], B[k][j]) to arrive on the same cycle for
every k. An A value injected at the west edge of row i takes j hops to reach
column j, and a B value injected at the north edge of column j takes i hops
to reach row i. Both arrive at PE(i,j) together if the controller injects:

- west edge, row i, cycle t: A[i][t-i], and zero outside 0 <= t-i < N
- north edge, col j, cycle t: B[t-j][j], and zero outside 0 <= t-j < N

Row 0 therefore starts immediately, row 1 one cycle later, and so on, forming
a diagonal wavefront. The zero padding is harmless because zero times any
value adds zero to an accumulator.

### Latency

The last useful element enters the edge at cycle 2N-2, then needs N-1 hops to
reach the far-corner PE and one more cycle to be absorbed, giving T = 3N-2
enabled cycles. For N = 4 this is 10, and the testbench measures 11 total
including the load cycle.

### Throughput

64 MACs in 10 feed cycles is an average of 6.4 MACs per cycle. Peak
utilization is N^2 = 16 MACs per cycle during the middle of the feed window
when every PE has valid data on both inputs. 

## Module hierarchy

```
matmul_top                        runtime select between the two engines
|-- sequential_matmul             V1: FSM plus a single shared MAC
\-- matmul_controller             V2: skew generator plus FSM
    \-- systolic_array            N x N wiring mesh
        \-- systolic_pe  (xN^2)   MAC plus east and south pass-through registers
pe_mac                            standalone MAC building block, used for
                                  synthesis experiments
```
