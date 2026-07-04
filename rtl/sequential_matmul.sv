//==============================================================================
// sequential_matmul.sv - Version 1: the sequential baseline
//-----------------------------------------------------------------------------
// Computes C = A * B for N x N signed INT8 matrices using a single shared MAC
// unit and a small FSM, performing one multiply-accumulate per clock cycle.
//
// Purpose of the baseline:
//   1. It serves as the reference against which the systolic version is checked.
//   2. It establishes the baseline cycle count for the speedup comparison:
//      approximately N^3 compute cycles (one MAC per cycle) plus N^2 store
//      cycles. For N = 4 this is 64 MACs + 16 stores + a small overhead.
//
// Interface:
//   Full matrices are passed as two-dimensional unpacked array ports
//   which is convenient in simulation. 
//   
//   The handshake is start/busy/done:
//     - pulse 'start' for one cycle while idle,
//     - 'busy' is high during computation,
//     - 'done' goes high and remains high until the next 'start'.
//
// FSM states:
//   S_IDLE    wait for start
//   S_INIT    latch A and B into internal registers, zero the counters
//   S_COMPUTE iterate k = 0..N-1, accumulating A[i][k]*B[k][j]
//   S_STORE   write the finished accumulator into C[i][j] and advance (i,j)
//   S_DONE    raise done and wait to be restarted

// Combinational and Sequential logic:
// Combinational logic has no memory. The output is purely a function of the 
// current inputs. If you change an input, and the output changes instantly, 
// in the same instant, no clock involved.
//
// Sequential logic has memory. It holds state in flip-flops (registers) and only 
// updates on a clock edge. It remembers values from one clock tick to the next.
//
// Sized literals:
// A way to write a constant while explicitly stating its bit-width and number base.
// Format: <width>'<base><value>
// width = how many bits
// base = the letter telling you the number system: b = binary, d = decimal, h = hex
// value = the actual number
// 3'd2    // 3 bits wide, decimal, value 2 -> binary 010
// 1'b1    // 1 bit wide,  binary,  value 1 -> just  1
//==================================================================================

module sequential_matmul #(
  parameter int DATA_WIDTH  = 8,
  parameter int ACC_WIDTH   = 32,
  parameter int MATRIX_SIZE = 4
) (
  input  logic clk,
  input  logic rst_n,                                            // asynchronous, active low
  input  logic start,                                            // one-cycle pulse to begin
  // two input matrices
  input  logic signed [DATA_WIDTH-1:0] a_in [MATRIX_SIZE][MATRIX_SIZE],
  input  logic signed [DATA_WIDTH-1:0] b_in [MATRIX_SIZE][MATRIX_SIZE],
  // The result leaves the module as one flat packed bus. Flat ports behave
  // identically across tools, whereas unpacked output array ports are not handled 
  // consistently by some simulators. 
  // Layout is row-major: 
  // bits [(i*N+j+1)*ACC_WIDTH-1 : (i*N+j)*ACC_WIDTH] hold the signed two's-complement
  // value of C[i][j]. A generate block at the end of this file performs the
  // packing. Testbenches unpack with the same indexing.
  output logic [MATRIX_SIZE*MATRIX_SIZE*ACC_WIDTH-1:0] c_flat, // 16 cells × 32 bits each = 512 total bits
  output logic busy,
  output logic done
);

  //---------------------------------------------------------------------------
  // Local types and signals
  //---------------------------------------------------------------------------
  // ceil(log2(N)) bits are sufficient to count 0..N-1.
  // ceil(log2(N)) is the formula for "how many bits do I need to count up to n different things."
  localparam int IDXW = (MATRIX_SIZE <= 1) ? 1 : $clog2(MATRIX_SIZE);

  typedef enum logic [2:0] {
    // FSM states: sit idle, initialize, compute, store the result, signal done
    S_IDLE    = 3'd0,
    S_INIT    = 3'd1,
    S_COMPUTE = 3'd2,
    S_STORE   = 3'd3,
    S_DONE    = 3'd4
  } state_t;

  state_t state, next_state;

  // Internal copies of the operand matrices, latched in S_INIT so that the
  // inputs a_in/b_in may change during computation without affecting the run.
  logic signed [DATA_WIDTH-1:0] a_reg [MATRIX_SIZE][MATRIX_SIZE];
  logic signed [DATA_WIDTH-1:0] b_reg [MATRIX_SIZE][MATRIX_SIZE];

  // Loop counters for C[i][j] = sum over k of A[i][k] * B[k][j].
  logic [IDXW-1:0] i_idx, j_idx, k_idx;

  // Result matrix held as a 2-D array for simple variable indexing. 
  // The generate block below packs it onto the flat output bus.
  logic signed [ACC_WIDTH-1:0] c_reg [MATRIX_SIZE][MATRIX_SIZE];

  // The single shared MAC accumulator and its product term.
  logic signed [ACC_WIDTH-1:0]    acc;
  logic signed [2*DATA_WIDTH-1:0] product;

  // "Counter is at its final value" flags.
  // Each flag is true when its counter hits its maximum (3 for a 4×4 matrix).
  logic i_last, j_last, k_last;
  assign i_last = (i_idx == IDXW'(MATRIX_SIZE-1));
  assign j_last = (j_idx == IDXW'(MATRIX_SIZE-1));
  assign k_last = (k_idx == IDXW'(MATRIX_SIZE-1));

  // Signed multiply of the currently selected operands.
  assign product = a_reg[i_idx][k_idx] * b_reg[k_idx][j_idx];

  //---------------------------------------------------------------------------
  // FSM next-state logic (combinational)
  //---------------------------------------------------------------------------
  // always_comb is a block of combinational logic (no memory, recomputes whenever inputs change)
  always_comb begin
    next_state = state; // default: hold
    unique case (state)
      S_IDLE:    if (start)  next_state = S_INIT;
      S_INIT:                next_state = S_COMPUTE;
      S_COMPUTE: if (k_last) next_state = S_STORE;          // dot product complete
      S_STORE:   if (i_last && j_last) next_state = S_DONE; // last C element written
                 else                  next_state = S_COMPUTE;
      S_DONE:    if (start)  next_state = S_INIT;           // allow back-to-back runs
      default:               next_state = S_IDLE;
    endcase
  end

  //---------------------------------------------------------------------------
  // FSM registered state and datapath
  //---------------------------------------------------------------------------
  // always_ff is sequential (clocked) logic. It triggers on a rising clock edge or a falling edge of reset. 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      i_idx <= '0; j_idx <= '0; k_idx <= '0;
      acc   <= '0;
    end else begin
      state <= next_state;

      unique case (state)
        S_INIT: begin
          // Latch the inputs. The for-loop in always_ff unrolls into N*N parallel register loads.
          for (int r = 0; r < MATRIX_SIZE; r++) begin
            for (int c = 0; c < MATRIX_SIZE; c++) begin
              // snapshot both input matrices into the internal registers
              a_reg[r][c] <= a_in[r][c];
              b_reg[r][c] <= b_in[r][c];
            end
          end
          i_idx <= '0; j_idx <= '0; k_idx <= '0;
          acc   <= '0;
        end

        S_COMPUTE: begin
          acc <= acc + product;              // one MAC per cycle. acc holds the
          if (k_last) k_idx <= '0;           // full dot product when S_STORE is
          else        k_idx <= k_idx + 1'b1; // entered
        end

        S_STORE: begin
          c_reg[i_idx][j_idx] <= acc;        // commit C[i][j]
          acc <= '0;                         // reset for the next dot product
          if (j_last) begin                  // j advances fast, i advances slow
            j_idx <= '0;
            if (!i_last) i_idx <= i_idx + 1'b1;
          end else begin
            j_idx <= j_idx + 1'b1;
          end
        end

        default: ; // S_IDLE and S_DONE hold all state
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Status outputs (Moore style: a function of state only)
  //---------------------------------------------------------------------------
  assign busy = (state == S_INIT) || (state == S_COMPUTE) || (state == S_STORE);
  assign done = (state == S_DONE);

  //---------------------------------------------------------------------------
  // Pack the 2-D result array onto the flat output bus. The genvar indices are
  // compile-time constants, so it costs no logic and is supported by the 
  // simulator and synthesizer.
  //---------------------------------------------------------------------------
  
  // A generate block with genvar loops runs at compile time. It's a code-generation 
  // template, not runtime logic. It produces 16 separate assign statements, one per result cell, 
  // wiring c_reg[gi][gj] into the correct 32-bit window of the flat 512-bit bus.
  
  // The +: operator is a part-select: c_flat[base +: ACC_WIDTH] means starting at bit base, take ACC_WIDTH (32) bits going up." 
  // The base address (gi*MATRIX_SIZE + gj)*ACC_WIDTH lays the cells out row-major, so C[0][0] sits in the lowest 32 bits, C[0][1] 
  // in the next 32, and so on. 
  genvar gi, gj;
  generate
    for (gi = 0; gi < MATRIX_SIZE; gi++) begin : g_pack_row
      for (gj = 0; gj < MATRIX_SIZE; gj++) begin : g_pack_col
        assign c_flat[(gi*MATRIX_SIZE + gj)*ACC_WIDTH +: ACC_WIDTH] = c_reg[gi][gj];
      end
    end
  endgenerate

endmodule : sequential_matmul
