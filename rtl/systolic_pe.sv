//=============================================================================
// systolic_pe.sv - one processing element (PE) of the systolic array
//-----------------------------------------------------------------------------
// In a systolic array, data advances through a grid of small processors in
// lock-step. Each PE performs three actions per cycle:
//
//   1. Multiply the A value arriving from the WEST by the B value arriving
//      from the NORTH and add the product to a local accumulator.
//   2. Forward the A value one hop EAST  (a_out <= a_in).
//   3. Forward the B value one hop SOUTH (b_out <= b_in).
//
// Each PE(i,j) owns one output element of the output matrix C[i][j], which 
// accumulates in place while A streams rightward and B streams downward.
//
// Why the result is correct:
// The A and B values are each delayed by exactly one register per hop. When
// the controller skews the inputs at the array edges, a[i][k] and b[k][j] arrive 
// at PE(i,j) on the same cycle for every k, so the accumulator sums all N products. 
// Values outside the valid window are fed as zero, and zero times anything is zero, 
// so padding cycles do not affect the accumulator.
//
// Accumulate timing:
// The product of the incoming a_in and b_in is added to the accumulator on the same 
// edge that registers the pass-through outputs. A and B see identical per-hop delay, 
// so the alignment holds.
//=============================================================================

module systolic_pe #(
  parameter int DATA_WIDTH = 8,
  parameter int ACC_WIDTH  = 32
) (
  input  logic                         clk,
  input  logic                         rst_n,   // asynchronous reset, active low
  input  logic                         clear,   // synchronous: zero the accumulator for a new operation on a clock edge
  input  logic                         en,      // advance the wave and accumulate
  input  logic signed [DATA_WIDTH-1:0] a_in,    // from the WEST neighbor (or array edge)
  input  logic signed [DATA_WIDTH-1:0] b_in,    // from the NORTH neighbor (or array edge)
  output logic signed [DATA_WIDTH-1:0] a_out,   // to the EAST neighbor
  output logic signed [DATA_WIDTH-1:0] b_out,   // to the SOUTH neighbor
  output logic signed [ACC_WIDTH-1:0]  c_acc    // this PE's C[i][j] result
);

  logic signed [2*DATA_WIDTH-1:0] product; // holds multiplication of two incoming values
  assign product = a_in * b_in;   // signed x signed = signed 16-bit product

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      c_acc <= '0;
    end else begin
      if (clear) begin
        c_acc <= '0;              // start a new accumulation
        a_out <= '0;
        b_out <= '0;
      end else if (en) begin
        a_out <= a_in;            // forward EAST
        b_out <= b_in;            // forward SOUTH
        c_acc <= c_acc + product; // sign-extended add (all operands signed)
      end
      // When en is low the PE holds its state, so the array can be paused.
    end
  end

endmodule : systolic_pe
