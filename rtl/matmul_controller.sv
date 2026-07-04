//=============================================================================
// matmul_controller.sv - feeds the systolic array with skewed data
//-----------------------------------------------------------------------------
// Version 2 wrapper. It holds the full A and B matrices and, on 'start',
// streams them into the systolic array edges with the correct relative timing
// (the input skew), then raises 'done' once every accumulator holds its final
// C value.
//
// Input skew:
//   PE(i,j) must receive the pair (A[i][k], B[k][j]) on the same cycle for
//   each k = 0..N-1. An A value injected at the west edge of row i takes j
//   cycles to reach column j. A B value injected at the north edge of column j
//   takes i cycles to reach row i. Both arrive at PE(i,j) on the same cycle if
//   the injection schedule is:
//
//       west edge,  row i, cycle t :  A[i][t - i]   when 0 <= t-i < N
//       north edge, col j, cycle t :  B[t - j][j]   when 0 <= t-j < N
//
//   and zero is injected outside that window. Row 0 starts immediately, row 1
//   one cycle later, and so on, forming a diagonal wavefront. Zero padding is
//   safe because zero times any value adds nothing to an accumulator.
//
// Cycle count to completion:
//   The last useful element (k = N-1) enters row/column N-1 at edge cycle
//   t = (N-1) + (N-1) = 2N-2, then needs up to N-1 further hops to reach the
//   far corner PE(N-1, N-1) and one more cycle to be absorbed. The compute
//   window is therefore:
//
//       T_compute = (2N - 2) + (N - 1) + 1 = 3N - 2   enabled cycles.
//
//   For N = 4 this is 10 cycles (compared to about 80 for the sequential
//   baseline) for the same 64 MACs, reaching up to N^2 = 16 MACs per cycle at
//   peak. The design runs exactly 3N-2 enabled cycles, counted by cycle_cnt.
//
// FSM: S_IDLE -> S_LOAD (latch A,B and clear the array) -> S_FEED (3N-2 cycles)
//      -> S_DONE (results valid) -> back to S_IDLE on the next start.
//=============================================================================

module matmul_controller #(
  parameter int DATA_WIDTH  = 8,
  parameter int ACC_WIDTH   = 32,
  parameter int MATRIX_SIZE = 4    // array size equals matrix size in this design
) (
  input  logic clk,
  input  logic rst_n,                                          // asynchronous, active low
  input  logic start,                                          // one-cycle pulse to begin
  input  logic signed [DATA_WIDTH-1:0] a_in [MATRIX_SIZE][MATRIX_SIZE],
  input  logic signed [DATA_WIDTH-1:0] b_in [MATRIX_SIZE][MATRIX_SIZE],
  output logic [MATRIX_SIZE*MATRIX_SIZE*ACC_WIDTH-1:0] c_flat, // flat row-major bus
  output logic busy,
  output logic done
);
 
  //---------------------------------------------------------------------------
  // Derived constants. Computed from the parameters so nothing is hardcoded and
  // the module rescales automatically when MATRIX_SIZE changes.
  //---------------------------------------------------------------------------
  localparam int N        = MATRIX_SIZE;          
  localparam int T_FEED   = 3*N - 2;              // enabled cycles required
  localparam int CNTW     = $clog2(T_FEED + 1);   // cycle-counter width
 
  // T_FEED derivation: the last useful operand enters the array at edge cycle
  // 2N-2, needs up to N-1 further hops to reach corner PE(N-1,N-1), and one
  // cycle to be absorbed, giving (2N-2)+(N-1)+1 = 3N-2. For N=4 this is 10
  // enabled cycles versus roughly 80 for the sequential baseline.
 
  typedef enum logic [1:0] {
    S_IDLE = 2'd0,
    S_LOAD = 2'd1,   // latch operands and clear accumulators (one cycle)
    S_FEED = 2'd2,   // stream skewed data for T_FEED cycles
    S_DONE = 2'd3
  } state_t;
 
  state_t state, next_state;
 
  // Latched operand matrices.
  // Snapshotting in S_LOAD decouples the run from a_in/b_in, which may change
  // during computation without affecting the result.
  logic signed [DATA_WIDTH-1:0] a_reg [N][N];
  logic signed [DATA_WIDTH-1:0] b_reg [N][N];
 
  // Global cycle counter t. It is active during S_FEED.
  // Drives the entire diagonal wavefront: the skew generator reads it every
  // cycle to decide which operand (or zero) each edge lane injects.
  logic [CNTW-1:0] cycle_cnt;
 
  // Edge feeds into the array, computed combinationally from t.
  // a_feed drives the west edge (one lane per row) 
  // b_feed drives the north edge (one lane per column).
  logic signed [DATA_WIDTH-1:0] a_feed [N];
  logic signed [DATA_WIDTH-1:0] b_feed [N];
 
  // Array control. Derived from state below and broadcast to every PE.
  logic arr_clear, arr_en;
 
  //---------------------------------------------------------------------------
  // Skew generator: select the correct element or zero for each edge lane.
  // The (t - i) index is computed in integer math. The guard condition ensures
  // it is in range before it is used to index the operand array.
  //
  // Schedule: at cycle t the west edge of row i injects
  // A[i][t-i] and the north edge of column i injects B[t-i][i], each valid only
  // while 0 <= t-i < N. Row/column i is therefore delayed by i cycles, forming
  // the diagonal wavefront. Every other cycle injects zero.
  //
  // The loop over i unrolls into N independent lane selectors (parallel muxes),
  // not a sequential iteration.
  //---------------------------------------------------------------------------
  always_comb begin
    for (int i = 0; i < N; i++) begin
      // Row i of A enters the west edge, delayed by i cycles.
      // int' casts guard against unsigned wraparound when forming t - i.
      if ((state == S_FEED) &&
          (int'(cycle_cnt) >= i) && (int'(cycle_cnt) - i < N))
        a_feed[i] = a_reg[i][int'(cycle_cnt) - i];   // column index advances with t
      else
        a_feed[i] = '0;   // zero padding contributes 0 to every accumulator
 
      // Column i of B enters the north edge, delayed by i cycles.
      // Index order is transposed relative to A: B streams south, so its row
      // index advances with t while the column index is fixed at i.
      if ((state == S_FEED) &&
          (int'(cycle_cnt) >= i) && (int'(cycle_cnt) - i < N))
        b_feed[i] = b_reg[int'(cycle_cnt) - i][i];
      else
        b_feed[i] = '0;
    end
  end
 
  //---------------------------------------------------------------------------
  // FSM next-state logic (combinational).
  // S_IDLE -> S_LOAD (on start) -> S_FEED (T_FEED cycles) -> S_DONE -> S_LOAD.
  //---------------------------------------------------------------------------
  always_comb begin
    next_state = state;   // default: hold
    unique case (state)
      S_IDLE: if (start) next_state = S_LOAD;
      S_LOAD:            next_state = S_FEED;
      // Leave S_FEED after exactly T_FEED enabled cycles (counting t = 0..T_FEED-1).
      S_FEED: if (cycle_cnt == CNTW'(T_FEED - 1)) next_state = S_DONE;
      S_DONE: if (start) next_state = S_LOAD;   // allow back-to-back runs
      default:           next_state = S_IDLE;
    endcase
  end
 
  //---------------------------------------------------------------------------
  // FSM registered state and cycle counter (sequential).
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      cycle_cnt <= '0;
    end else begin
      state <= next_state;
      unique case (state)
        S_LOAD: begin
          // Latch both operand matrices. The nested loop unrolls into 2*N*N
          // parallel register loads completing in this single cycle.
          for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++) begin
              a_reg[r][c] <= a_in[r][c];
              b_reg[r][c] <= b_in[r][c];
            end
          cycle_cnt <= '0;                  // restart t for the upcoming feed
        end
        S_FEED:  cycle_cnt <= cycle_cnt + 1'b1;   // advance the wavefront
        default: ;                                // S_IDLE and S_DONE hold state
      endcase
    end
  end
 
  //---------------------------------------------------------------------------
  // Array control and status (Moore style: functions of state only).
  //---------------------------------------------------------------------------
  // Array control: clear accumulators during S_LOAD, advance during S_FEED.
  assign arr_clear = (state == S_LOAD);
  assign arr_en    = (state == S_FEED);
  assign busy      = (state == S_LOAD) || (state == S_FEED);
  assign done      = (state == S_DONE);
 
  //---------------------------------------------------------------------------
  // The systolic array instance.
  // Skewed edge feeds drive a_row_in/b_col_in. The array's per-PE accumulators
  // are exposed directly on c_flat, so no separate result-collection stage is
  // needed.
  //---------------------------------------------------------------------------
  systolic_array #(
    .DATA_WIDTH (DATA_WIDTH),
    .ACC_WIDTH  (ACC_WIDTH),
    .ARRAY_N    (N)
  ) u_array (
    .clk      (clk),
    .rst_n    (rst_n),
    .clear    (arr_clear),
    .en       (arr_en),
    .a_row_in (a_feed),
    .b_col_in (b_feed),
    .c_flat   (c_flat)
  );
 
endmodule : matmul_controller
