//=============================================================================
// matmul_top.sv - project top level
//-----------------------------------------------------------------------------
// Wraps both accelerator versions behind a single interface so that one
// testbench, and one Quartus project, can use either engine:
//
//     sel_systolic = 0  ->  Version 1: sequential baseline (about N^3 cycles)
//     sel_systolic = 1  ->  Version 2: systolic array      (3N-2 cycles)
//
// The 'start' pulse is routed to the selected engine and the outputs are muxed
// back. Instantiating both engines lets a single Quartus compile report the
// resources of the combined design. To obtain per-engine numbers for the
// results table, compile each engine as its own top level.
//
// Pin assignment note:
//   The ports below are generic. With MATRIX_SIZE = 4 the flattened I/O is
//   16*8*2 = 256 input bits and 16*32 = 512 output bits, which exceeds the
//   pin count of any real board. This is acceptable for synthesis
//   characterization if the I/O is marked as virtual pins
//   (create_project.tcl does this), but it is not a deployable pinout. 
//   Actual pin locations must come from the specific Cyclone 10 GX board pin 
//   table. See quartus/notes_for_pin_assignments.md.
//=============================================================================

module matmul_top #(
  parameter int DATA_WIDTH  = 8,
  parameter int ACC_WIDTH   = 32,
  parameter int MATRIX_SIZE = 4
) (
  input  logic clk,
  input  logic rst_n,          // asynchronous, active low
  input  logic start,          // one-cycle pulse: begin a multiplication
  input  logic sel_systolic,   // 0 = sequential baseline, 1 = systolic array
  input  logic signed [DATA_WIDTH-1:0] a_in [MATRIX_SIZE][MATRIX_SIZE],
  input  logic signed [DATA_WIDTH-1:0] b_in [MATRIX_SIZE][MATRIX_SIZE],
  output logic [MATRIX_SIZE*MATRIX_SIZE*ACC_WIDTH-1:0] c_flat, // flat row-major, each 32-bit slice is signed C[i][j]
  output logic busy,
  output logic done
);
 
  // Per-engine handshake and result signals.
  // Each engine keeps its own start/busy/done and result bus. The wrapper
  // selects between them below rather than sharing state across the two.
  logic seq_start, sys_start;
  logic seq_busy,  sys_busy;
  logic seq_done,  sys_done;
  logic [MATRIX_SIZE*MATRIX_SIZE*ACC_WIDTH-1:0] seq_c;
  logic [MATRIX_SIZE*MATRIX_SIZE*ACC_WIDTH-1:0] sys_c;
 
  // Route the start pulse to the selected engine only.
  // Gating start means the unselected engine stays idle instead of running a
  // redundant computation, so only one engine is ever active per run.
  assign seq_start = start & ~sel_systolic;
  assign sys_start = start &  sel_systolic;
 
  // Version 1
  // Sequential baseline. Its a_in/b_in and c_flat are wired straight through.
  // Only its start is gated, so it advances only when selected.
  sequential_matmul #(
    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),
    .MATRIX_SIZE (MATRIX_SIZE)
  ) u_sequential (
    .clk   (clk),
    .rst_n (rst_n),
    .start (seq_start),
    .a_in  (a_in),
    .b_in  (b_in),
    .c_flat (seq_c),
    .busy  (seq_busy),
    .done  (seq_done)
  );
 
  // Version 2
  // Systolic engine (skew feeder plus PE array). Pin-compatible with the
  // sequential engine above, which is what allows the shared wrapper interface.
  matmul_controller #(
    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),
    .MATRIX_SIZE (MATRIX_SIZE)
  ) u_systolic (
    .clk   (clk),
    .rst_n (rst_n),
    .start (sys_start),
    .a_in  (a_in),
    .b_in  (b_in),
    .c_flat (sys_c),
    .busy  (sys_busy),
    .done  (sys_done)
  );
 
  // Output mux
  // The result buses are flat, so the mux is a single wide 2:1 select.
  assign c_flat = sel_systolic ? sys_c : seq_c;
 
  // Status mux: forward the selected engine's handshake so downstream logic
  // sees one coherent busy/done regardless of which engine is active.
  assign busy = sel_systolic ? sys_busy : seq_busy;
  assign done = sel_systolic ? sys_done : seq_done;
 
endmodule : matmul_top