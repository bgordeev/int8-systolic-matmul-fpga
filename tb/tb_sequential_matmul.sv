//=============================================================================
// tb_sequential_matmul.sv - self-checking testbench for Version 1
//-----------------------------------------------------------------------------
// Runs four directed test cases plus one hex-file test, computes the expected
// C with a golden function defined inside the testbench, and prints PASS or
// FAIL for each case.
//
// Run with Icarus Verilog (from the project root, so the hex paths resolve):
//   python3 scripts/generate_vectors.py
//   iverilog -g2012 -o sim_seq rtl/matmul_pkg.sv rtl/pe_mac.sv \
//            rtl/sequential_matmul.sv tb/tb_sequential_matmul.sv
//   vvp sim_seq
//
// Run with Questa or ModelSim:
// vlog -sv rtl/*.sv tb/tb_sequential_matmul.sv
// vsim -c work.tb_sequential_matmul -do "run -all; quit"
//=============================================================================

`timescale 1ns/1ps

module tb_sequential_matmul;

  // Geometry and clock timing.
  localparam int DATA_WIDTH  = 8;
  localparam int ACC_WIDTH   = 32;
  localparam int N           = 4;     // MATRIX_SIZE
  localparam int CLK_PERIOD  = 10;    // 100 MHz

  
  logic clk = 0, rst_n, start;
  logic signed [DATA_WIDTH-1:0] A [N][N];
  logic signed [DATA_WIDTH-1:0] B [N][N];
  logic busy, done;

  // Unpack the flat result bus into a 2-D signed array. The genvar
  // indices are constants.
  // Rebuilds C[i][j] from the flat bus using the same row-major slicing as the
  // RTL, so the checks can index results.
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


  // The sequential (Version 1) engine.
  sequential_matmul #(
    .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .MATRIX_SIZE(N)
  ) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .a_in(A), .b_in(B), .c_flat(C_flat), .busy(busy), .done(done)
  );

  always #(CLK_PERIOD/2) clk = ~clk;   // free-running clock

  //--------------------------------------------------------------------------
  // Golden model and scoreboard. The golden model is written independently of
  // the RTL. 
  //--------------------------------------------------------------------------
  logic signed [ACC_WIDTH-1:0] expected [N][N];
  int n_pass = 0, n_fail = 0;

  // Reference multiply. Operands are widened to ACC_WIDTH before multiplying so
  // the accumulation width matches the hardware datapath.
  function automatic void golden_matmul();
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        expected[i][j] = '0;
        for (int k = 0; k < N; k++)
          expected[i][j] += ACC_WIDTH'(A[i][k]) * ACC_WIDTH'(B[k][j]);
      end
  endfunction

  // Run one full multiplication and compare every element of C.
  // Pulses start for one cycle, counts cycles until done with a hang guard,
  // then checks every result element and tallies the outcome.
  task automatic run_and_check(string test_name);
    int errors = 0;
    int cycles = 0;
    golden_matmul();

    @(negedge clk); start = 1;          // one-cycle start pulse
    @(negedge clk); start = 0;
    while (!done) begin                  // measure latency in clock cycles
      @(negedge clk);
      cycles++;
      if (cycles > 10000) begin
        $display("FAIL [%s]: timeout, done never asserted", test_name);
        n_fail++; $finish;
      end
    end

    // Element-wise compare. Print each mismatch with its coordinate.
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
      $display("FAIL [%s]: %0d mismatching elements", test_name, errors);
      n_fail++;
    end
  endtask


  // Stimulus
  logic [7:0] A_mem [0:N*N-1];   // raw bytes read from the hex files
  logic [7:0] B_mem [0:N*N-1];

  initial begin
    $dumpfile("tb_sequential_matmul.vcd");   // waveform for GTKWave
    $dumpvars(0, tb_sequential_matmul);

    // Idle start and apply reset before the first pattern.
    start = 0; rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // Test 1: small positive numbers.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'(i + j + 1);   // 1..7
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'((i == j) ? 2 : 1);
    run_and_check("small_positive");

    // Test 2: negative numbers, to test signed arithmetic.
    foreach (A[i, j]) A[i][j] = -DATA_WIDTH'(i + 1);      // -1..-4 per row
    foreach (B[i, j]) B[i][j] = (j % 2 == 0) ? DATA_WIDTH'(3) : -DATA_WIDTH'(5);
    run_and_check("negatives");

    // Test 3: all zeros, so C must be exactly zero.
    foreach (A[i, j]) A[i][j] = '0;
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'(7);
    run_and_check("zeros");

    // Test 4: random INT8 of limited magnitude, so the inputs do not overflow
    // INT8 and the result stays inside ACC_WIDTH.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'($urandom_range(0, 40)) - DATA_WIDTH'(20);
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'($urandom_range(0, 40)) - DATA_WIDTH'(20);
    run_and_check("random_limited");

    // Test 5: vectors produced by the Python golden model.
    // Reading the same files the RTL flow consumes confirms this engine agrees
    // with the external reference, not just the in-testbench golden function.
    $readmemh("vectors/A_matrix.hex", A_mem);
    $readmemh("vectors/B_matrix.hex", B_mem);
    foreach (A[i, j]) A[i][j] = signed'(A_mem[i*N + j]);  // reinterpret bytes as signed
    foreach (B[i, j]) B[i][j] = signed'(B_mem[i*N + j]);
    run_and_check("python_hex_vectors");

    // Summary
    $display("\n==== tb_sequential_matmul: %0d passed, %0d failed ====",
             n_pass, n_fail);
    if (n_fail == 0) $display("ALL TESTS PASS");
    else             $display("SOME TESTS FAILED");
    $finish;
  end

endmodule : tb_sequential_matmul