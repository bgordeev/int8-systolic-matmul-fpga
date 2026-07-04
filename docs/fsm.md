# FSM Design

Both engines use Moore-style finite state machines, in which the outputs
depend only on the current state. Each FSM is written in the standard
two-block style. A combinational `always_comb` block computes the next state
and a clocked `always_ff` block registers the state and datapath signals.

## Version 1: sequential_matmul.sv

```
            start                    k == N-1
  +--------+ --> +--------+ --> +-----------+ ------> +---------+
  | S_IDLE |     | S_INIT |     | S_COMPUTE | <------ | S_STORE |
  +--------+     +--------+     +-----------+ not last +----+----+
       ^                                                    | i,j last
       |                 start (rerun)                 +----v----+
       +--------------------------------------------   | S_DONE  |
                                                       +---------+
```

| State     | Action                                                        | Cycles      |
|-----------|---------------------------------------------------------------|-------------|
| S_IDLE    | Wait for start.                                               | n/a         |
| S_INIT    | Latch A and B into internal registers, zero counters and acc. | 1           |
| S_COMPUTE | acc += A[i][k]*B[k][j], advance k.                            | N per (i,j) |
| S_STORE   | Write acc into C[i][j], clear acc, advance j then i.          | 1 per (i,j) |
| S_DONE    | Hold done high until the next start.                          | n/a         |

Total latency is 1 + N^3 + N^2 cycles, which is 81 for N = 4 (verified in
simulation).

Notable design choices:

- The inputs are latched in S_INIT, so surrounding logic may change a_in and
  b_in during computation without corrupting the run.
- Counters use ceil(log2(N)) bits, keeping the parameterization consistent
  across N.

## Version 2: matmul_controller.sv

```
   start          1 cycle       cycle_cnt == 3N-3
 S_IDLE --> S_LOAD --> S_FEED ---------------------> S_DONE --(start)--> S_LOAD
            (latch A,B,  (drive skewed a_feed/b_feed,
             clear PEs)   en = 1 for exactly 3N-2 cycles)
```

| State  | Array control       | Purpose                                        |
|--------|---------------------|------------------------------------------------|
| S_LOAD | clear = 1, en = 0   | Zero all N^2 accumulators and latch A and B.   |
| S_FEED | clear = 0, en = 1   | Drive the skewed wavefront for 3N-2 cycles.    |
| S_DONE | clear = 0, en = 0   | Accumulators are frozen and hold valid results.|

The substantive logic is the skew generator rather than the FSM itself. Given
the cycle count t, it selects A[i][t-i] or B[t-j][j], or zero, for each edge
lane. See [architecture.md](architecture.md) for the skew derivation.

## Why both done and busy

The busy signal tells an upstream producer not to change the inputs or
restart the engine. The done signal tells a downstream consumer that the
results are valid. During S_IDLE the engine is neither busy nor done. 
Keeping them separate avoids a common integration error where a single 
status line is ambiguous.
