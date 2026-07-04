//=============================================================================
// pe_mac.sv
//-----------------------------------------------------------------------------
// A single multiply-accumulate (MAC) unit.
//
// Function: while 'en' is asserted, each clock computes acc <= acc + (a * b).
// A dot product isa sequence of MACs, and a matrix multiply is a grid of dot products.
//
// Signed arithmetic:
// Both operands and the accumulator are declared 'signed'. Because every
// term in 'acc + a * b' is signed, the tool performs a signed multiply and
// sign-extends the product to ACC_WIDTH before the addition. If any operand
// were unsigned, the entire expression would be evaluated as unsigned and
// the negative values would be computed incorrectly.
//
// Overflow:
// An INT8 x INT8 product fits in 16 bits. 
// Summing K products needs 16 + ceil(log2(K)) bits.
// ACC_WIDTH = 32 is safe for the matrix sizes.
//
// Synthesis:
// On Cyclone 10 GX, Quartus maps 'a * b' onto a hardened DSP block. 
// Each variable-precision DSP supports an 18x19 multiply, so an 8x8 signed
// multiply fits in one block.
//=============================================================================

module pe_mac #(
  parameter int DATA_WIDTH = 8,   // input operand width (signed)
  parameter int ACC_WIDTH  = 32   // accumulator width (signed)
) (
  input  logic                          clk,
  input  logic                          rst_n,  // asynchronous reset, active low
  input  logic                          clear,  // synchronous clear: acc <= 0 to start a new dot product
  input  logic                          en,     // accumulate on this cycle when high
  input  logic signed [DATA_WIDTH-1:0]  a,      // multiplicand 
  input  logic signed [DATA_WIDTH-1:0]  b,      // multiplier   
  output logic signed [ACC_WIDTH-1:0]   acc     // running sum
);

  // The product is at most 2*DATA_WIDTH bits wide. 
  logic signed [2*DATA_WIDTH-1:0] product;
  assign product = a * b;   // signed * signed = signed product

// Accumulator register for the MAC operation.
// Asynchronously resets to zero when rst_n is low.
// When clear is asserted, the accumulator is reset to begin a new dot product.
// When en is asserted, the current product is added to the running sum.
// If en is low, the accumulator holds its previous value.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc <= '0;                 // reset: accumulator starts at zero
    else if (clear)
      acc <= '0;                 // clear: begin a fresh dot product
    else if (en)
      acc <= acc + product;      // product is sign-extended to ACC_WIDTH
  end

endmodule : pe_mac
