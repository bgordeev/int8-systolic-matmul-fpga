//=============================================================================
// tb_matmul_top.sv - integration testbench (both engines, hex vectors)
//-----------------------------------------------------------------------------
// Exercises matmul_top with sel_systolic = 0 and 1 on identical inputs:
//   - directed tests (positives, negatives, zeros, random limited-magnitude),
//   - the Python-generated hex vectors, checked against C_expected.hex,
//   - a cross-check requiring both engines to produce identical results,
//   - a latency measurement for each engine, used in the synthesis results.
//
// It also writes the systolic hex-vector result to vectors/C_hw_out.hex so
// that scripts/verify_results.py can perform an independent software check.
//
// Run (from the project root, after generating vectors):
//   iverilog -g2012 -o sim_top rtl/matmul_pkg.sv rtl/pe_mac.sv \
//     rtl/sequential_matmul.sv rtl/systolic_pe.sv rtl/systolic_array.sv \
//     rtl/matmul_controller.sv rtl/matmul_top.sv tb/tb_matmul_top.sv
//   vvp sim_top
//   python3 scripts/verify_results.py
//=============================================================================

`timescale 1ns/1ps
 
module tb_matmul_top;
 
  // Geometry and clock timing.
  localparam int DATA_WIDTH = 8;
  localparam int ACC_WIDTH  = 32;
  localparam int N          = 4;
  localparam int CLK_PERIOD = 10;
 
  // Stimulus and response signals.
  logic clk = 0, rst_n, start, sel_systolic;
  logic signed [DATA_WIDTH-1:0] A [N][N];
  logic signed [DATA_WIDTH-1:0] B [N][N];
  logic busy, done;
 
  // Unpack the flat result bus into a 2-D signed array. 
  // Reconstructs C[i][j] from the flat bus with the same row-major slicing as
  // the RTL.
  logic [N*N*ACC_WIDTH-1:0]    C_flat;
  logic signed [ACC_WIDTH-1:0] C [N][N];
  genvar ugi, ugj;
  generate
    for (ugi = 0; ugi < N; ugi++) begin : g_unpack_row
      for (ugj = 0; ugj < N; ugj++) begin : g_unpack_col
        assign C[ugi][ugj] = C_flat[(ugi*N + ugj)*ACC_WIDTH +: ACC_WIDTH];
      end
    end
  endgenerate
 
 
  // The wrapper holding both engines and the select bit.
  matmul_top #(
    .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .MATRIX_SIZE(N)
  ) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .sel_systolic(sel_systolic),
    .a_in(A), .b_in(B), .c_flat(C_flat), .busy(busy), .done(done)
  );
 
  always #(CLK_PERIOD/2) clk = ~clk;
 
  // Golden model and bookkeeping
  logic signed [ACC_WIDTH-1:0] expected   [N][N];
  logic signed [ACC_WIDTH-1:0] seq_result [N][N]; // saved for the cross-check
  int n_pass = 0, n_fail = 0;
  int seq_cycles, sys_cycles;                     // measured latencies
 
  // Reference multiply computed independently of the DUT. Operands are widened
  // to ACC_WIDTH before multiplying so the accumulation matches the hardware.
  function automatic void golden_matmul();
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        expected[i][j] = '0;
        for (int k = 0; k < N; k++)
          expected[i][j] += ACC_WIDTH'(A[i][k]) * ACC_WIDTH'(B[k][j]);
      end
  endfunction
 
  // Run the currently selected engine once and return its latency in 'cycles'.
  // Sampling on negedge keeps stimulus away from the active posedge. 
  // Aborts the run if done never arrives.
  task automatic run_engine(output int cycles);
    cycles = 0;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    while (!done) begin
      @(negedge clk);
      cycles++;
      if (cycles > 10000) begin
        $display("FAIL: timeout waiting for done"); n_fail++; $finish;
      end
    end
  endtask
 
  // Compare C against 'expected' and report under 'test_name'.
  // Each mismatching cell is printed with its coordinate.
  task automatic check(string test_name, int cycles);
    int errors = 0;
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        if (C[i][j] !== expected[i][j]) begin
          errors++;
          $display("   mismatch C[%0d][%0d]: got %0d, expected %0d",
                   i, j, $signed(C[i][j]), expected[i][j]);
        end
    if (errors == 0) begin
      $display("PASS [%s]  (latency: %0d cycles)", test_name, cycles);
      n_pass++;
    end else begin
      $display("FAIL [%s]: %0d mismatches", test_name, errors); n_fail++;
    end
  endtask
 
  // Run both engines on the same A and B, check each, and cross-compare.
  task automatic run_both(string base_name);
    int cyc, xerr;
    golden_matmul();
 
    // Sequential engine first, then save its result for the cross check.
    sel_systolic = 0;
    run_engine(cyc); seq_cycles = cyc;
    check({base_name, "_sequential"}, cyc);
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) seq_result[i][j] = C[i][j];
 
    // Systolic engine on the same operands.
    sel_systolic = 1;
    run_engine(cyc); sys_cycles = cyc;
    check({base_name, "_systolic"}, cyc);
 
    // Cross-check plus the measured speedup.
    xerr = 0;
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        if (C[i][j] !== seq_result[i][j]) xerr++;
    if (xerr == 0) begin
      $display("PASS [%s_crosscheck]  engines agree; speedup = %0.1fx",
               base_name, real'(seq_cycles)/real'(sys_cycles));
      n_pass++;
    end else begin
      $display("FAIL [%s_crosscheck]: engines disagree on %0d elements",
               base_name, xerr);
      n_fail++;
    end
  endtask
 
  // Stimulus
  // Raw byte and word buffers for the hex vectors.
  logic [7:0]  A_mem [0:N*N-1];
  logic [7:0]  B_mem [0:N*N-1];
  logic [31:0] C_mem [0:N*N-1];
  int fd;
 
  initial begin
    // Waveform dump.
    $dumpfile("tb_matmul_top.vcd");
    $dumpvars(0, tb_matmul_top);
 
    // Apply reset before the first test.
    start = 0; sel_systolic = 0; rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
 
    // Directed tests on both engines.
    // Each block loads a pattern into A and B, then run_both checks both
    // engines and their agreement. small_positive is the baseline case.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'(i + j);
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'(j + 1);
    run_both("small_positive");
 
    // Negative operands with signed multiply and accumulation.
    foreach (A[i, j]) A[i][j] = -DATA_WIDTH'(i + 3);
    foreach (B[i, j]) B[i][j] = (j % 2 == 0) ? DATA_WIDTH'(6) : -DATA_WIDTH'(2);
    run_both("negatives");
 
    // Zero A forces C to zero regardless of B, even at INT8.
    foreach (A[i, j]) A[i][j] = '0;
    foreach (B[i, j]) B[i][j] = -DATA_WIDTH'(128);   // most negative INT8
    run_both("zeros_and_extreme");
 
    // Randomized limited-magnitude operands for broader coverage.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'($urandom_range(0, 50)) - DATA_WIDTH'(25);
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'($urandom_range(0, 50)) - DATA_WIDTH'(25);
    run_both("random_limited");
 
    // Hex-vector test: A and B come from Python. The expected result is loaded
    // from C_expected.hex rather than recomputed.
    // This closes the loop with the vector generator, checking the hardware
    // against a golden value.
    $readmemh("vectors/A_matrix.hex",   A_mem);
    $readmemh("vectors/B_matrix.hex",   B_mem);
    $readmemh("vectors/C_expected.hex", C_mem);
    foreach (A[i, j]) A[i][j] = signed'(A_mem[i*N + j]);
    foreach (B[i, j]) B[i][j] = signed'(B_mem[i*N + j]);
    foreach (expected[i, j]) expected[i][j] = signed'(C_mem[i*N + j]);
 
    // Run both engines against the loaded golden vectors.
    sel_systolic = 0;
    run_engine(seq_cycles);  check("hexfile_sequential", seq_cycles);
    sel_systolic = 1;
    run_engine(sys_cycles);  check("hexfile_systolic",  sys_cycles);
 
    // Write the systolic hardware output for scripts/verify_results.py.
    // Returning the result as hex lets an independent Python check re-verify it
    // outside the simulator.
    fd = $fopen("vectors/C_hw_out.hex", "w");
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        $fdisplay(fd, "%08x", C[i][j]);
    $fclose(fd);
    $display("Wrote vectors/C_hw_out.hex (systolic result) for verify_results.py");
 
    // Summary
    // Report the tally and the measured latencies.
    $display("\n==== tb_matmul_top: %0d passed, %0d failed ====", n_pass, n_fail);
    $display("Latency, hex test: sequential = %0d cycles, systolic = %0d cycles",
             seq_cycles, sys_cycles);
    if (n_fail == 0) $display("ALL TESTS PASS");
    else             $display("SOME TESTS FAILED");
    $finish;
  end
 
endmodule : tb_matmul_top