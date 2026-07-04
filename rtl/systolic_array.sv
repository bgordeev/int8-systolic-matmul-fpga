//=============================================================================
// systolic_array.sv - an ARRAY_N x ARRAY_N grid of systolic PEs
//-----------------------------------------------------------------------------
// This module instantiates ARRAY_N*ARRAY_N copies of
// systolic_pe and connects them into a two-dimensional mesh.
//
//                 b_col_in[0]   b_col_in[1]   ...   (B enters from the NORTH)
//                     |             |
//                     v             v
//   a_row_in[0] --> PE(0,0) ----> PE(0,1) ----> ...   (A enters from the WEST)
//                     |             |
//                     v             v
//   a_row_in[1] --> PE(1,0) ----> PE(1,1) ----> ...
//                     |             |
//                     v             v
//                    ...           ...
//
// Horizontal links carry A values, one register delay per hop.
// Vertical links carry B values, one register delay per hop.
// Each PE(i,j) accumulates C[i][j] locally.
//
// Scaling: 
// The module is fully parameterized. ARRAY_N = 2 produces a 4-PE
// array small enough to trace manually. ARRAY_N = 4 matches the default 4x4
// matrices. The MAC count grows as ARRAY_N^2, which is the resource-versus-
// throughput tradeoff measured in the synthesis results.
//
// The control logic that decides when to feed each value is located in
// matmul_controller.sv.
//=============================================================================

module systolic_array #(
  parameter int DATA_WIDTH = 8,
  parameter int ACC_WIDTH  = 32,
  parameter int ARRAY_N    = 4
) (
  input  logic clk,
  input  logic rst_n,
  input  logic clear,                                        // zero all accumulators
  input  logic en,                                           // advance the systolic wave
  input  logic signed [DATA_WIDTH-1:0] a_row_in [ARRAY_N],   // west edge feed, one per row
  input  logic signed [DATA_WIDTH-1:0] b_col_in [ARRAY_N],   // north edge feed, one per column
  // Flat result bus, row-major: bits [(i*N+j)*ACC_WIDTH +: ACC_WIDTH] hold the
  // signed C[i][j] from PE(i,j). 
  output logic [ARRAY_N*ARRAY_N*ACC_WIDTH-1:0] c_flat
);

  // Internal mesh wires. Index [i][j] is the signal ENTERING PE(i,j):
  //   a_wire[i][j] arrives from the west (PE(i,j-1), or the edge when j == 0)
  //   b_wire[i][j] arrives from the north (PE(i-1,j), or the edge when i == 0)
  // One extra column and row hold the outputs of the last PEs, which are left
  // unconnected because the data has completed its traversal by that point.
  logic signed [DATA_WIDTH-1:0] a_wire [ARRAY_N][ARRAY_N+1];
  logic signed [DATA_WIDTH-1:0] b_wire [ARRAY_N+1][ARRAY_N];

  // Connect the array edges to the external feeds.
  genvar gi, gj;
  generate
    for (gi = 0; gi < ARRAY_N; gi++) begin : g_edge_a
      assign a_wire[gi][0] = a_row_in[gi];   // west edge of row gi
    end
    for (gj = 0; gj < ARRAY_N; gj++) begin : g_edge_b
      assign b_wire[0][gj] = b_col_in[gj];   // north edge of column gj
    end

    // Instantiate the PE grid.

    for (gi = 0; gi < ARRAY_N; gi++) begin : g_row
      for (gj = 0; gj < ARRAY_N; gj++) begin : g_col
        systolic_pe #(
          .DATA_WIDTH (DATA_WIDTH),
          .ACC_WIDTH  (ACC_WIDTH)
        ) u_pe (
          .clk   (clk),
          .rst_n (rst_n),
          .clear (clear),
          .en    (en),
          // a_in <- a_wire[gi][gj] - the cell reads its incoming A from the wire entering it from the west.
          .a_in  (a_wire[gi][gj]),     // from west
          // b_in <- b_wire[gi][gj] - incoming B from the north.
          .b_in  (b_wire[gi][gj]),     // from north
          // a_out -> a_wire[gi][gj+1] - the cell's A output drives the wire at column gj+1, which is exactly 
          // the wire that PE(gi, gj+1) reads as its a_in. So this cell's east output automatically becomes 
          // the next cell's west input. 
          .a_out (a_wire[gi][gj+1]),   // to east
          // b_out -> b_wire[gi+1][gj] - B output drives row gi+1's wire, which is the b_in of the cell directly below.
          .b_out (b_wire[gi+1][gj]),   // to south
          // Wire this PE's accumulator straight into its own 32-bit window of the
          // flat result bus. Row-major: PE(i,j) lands at linear slot (i*N + j), so
          // C[0][0] occupies the lowest ACC_WIDTH bits, C[0][1] the next, and so on.
          // '+:' is an ascending part-select (start bit, then width).
          .c_acc (c_flat[(gi*ARRAY_N + gj)*ACC_WIDTH +: ACC_WIDTH])
        );
      end
    end
  endgenerate

endmodule : systolic_array
