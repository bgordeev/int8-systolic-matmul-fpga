//=============================================================================
// matmul_pkg.sv
//-----------------------------------------------------------------------------
// Shared parameter file for the INT8 matrix-multiply accelerator.
//
// A SystemVerilog package defines constants and types so that all modules
// share one source. Each module still declares its own parameters and
// can be overridden.
//
// Width rationale:
// DATA_WIDTH = 8   Inputs are signed INT8 (range -128 to +127)
// ACC_WIDTH  = 32  The accumulator is wider than the inputs to hold the sum
//                  of many products without overflow.
//
// 
// One signed INT8 x INT8 product needs 16 bits
// The worst case is (-128) * (-128) = +16384.
// A dot product of length K sums K such products
// and therefore needs 16 + ceil(log2(K)) bits. 
// A 32-bit accumulator is safe for K up to 2^16 terms.
//=============================================================================

package matmul_pkg;

  // Element width of matrix A and B entries (signed INT8).
  parameter int DATA_WIDTH  = 8;

  // Accumulator and output width of matrix C entries (signed INT32).
  parameter int ACC_WIDTH   = 32;

  // Square matrix dimension: C(N x N) = A(N x N) * B(N x N).
  parameter int MATRIX_SIZE = 4;

  // Systolic array dimension. The array matches the matrix size: the mapping
  // is output-stationary, with one processing element per C element.
  parameter int ARRAY_N     = 4;

endpackage : matmul_pkg
