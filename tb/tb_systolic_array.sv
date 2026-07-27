//=============================================================================
// tb_systolic_array.sv - tests the raw array without the controller
//-----------------------------------------------------------------------------
// This testbench drives the systolic_array module directly and generates the
// input skew itself. Its purpose is to verify the array wiring and PE
// arithmetic in isolation, so that if the integrated top-level test later
// fails, the fault can be localized to the controller rather than the array.
// Verifying each layer before integration is standard practice.
//
// The testbench re-implements the skew schedule independently of the RTL:
//     west edge,  row i, cycle t:  A[i][t-i]  if 0 <= t-i < N, else 0
//     north edge, col j, cycle t:  B[t-j][j]  if 0 <= t-j < N, else 0
// for T = 3N-2 enabled cycles. It encodes the correct schedule even
// if the controller implementation changes.
//
// Run (from the project root):
//   iverilog -g2012 -o sim_arr rtl/matmul_pkg.sv rtl/systolic_pe.sv \
//            rtl/systolic_array.sv tb/tb_systolic_array.sv && vvp sim_arr
//=============================================================================

`timescale 1ns/1ps

module tb_systolic_array;

  // Geometry, feed length, and clock timing. T_FEED tracks the 3N-2 schedule.
  localparam int DATA_WIDTH = 8;
  localparam int ACC_WIDTH  = 32;
  localparam int N          = 4;          // matrix / array dimension
  localparam int T_FEED     = 3*N - 2;
  localparam int CLK_PERIOD = 10;

  // Array controls and the two edge feeds driven by this testbench.
  logic clk = 0, rst_n, clear, en;
  logic signed [DATA_WIDTH-1:0] a_feed [N];
  logic signed [DATA_WIDTH-1:0] b_feed [N];

  // Unpack the flat result bus into a 2-D signed array. The genvar
  // indices are constants.
  // Each PE accumulator arrives on its own slice of C_flat. This rebuilds the
  // C[i][j] view.
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

  // The bare PE mesh, with no controller in the path.
  systolic_array #(
    .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .ARRAY_N(N)
  ) dut (
    .clk(clk), .rst_n(rst_n), .clear(clear), .en(en),
    .a_row_in(a_feed), .b_col_in(b_feed), .c_flat(C_flat)
  );

  always #(CLK_PERIOD/2) clk = ~clk;


  // Test matrices, golden model, scoreboard
  logic signed [DATA_WIDTH-1:0] A [N][N];
  logic signed [DATA_WIDTH-1:0] B [N][N];
  logic signed [ACC_WIDTH-1:0]  expected [N][N];
  int n_pass = 0, n_fail = 0;

  // Reference multiply, widened to ACC_WIDTH to match the accumulator.
  function automatic void golden_matmul();
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        expected[i][j] = '0;
        for (int k = 0; k < N; k++)
          expected[i][j] += ACC_WIDTH'(A[i][k]) * ACC_WIDTH'(B[k][j]);
      end
  endfunction

  // Stream one full matrix multiply through the array with manual skew.
  // This task reproduces the controller's job by
  // hand so the bare array is tested with a known-correct schedule.
  task automatic run_and_check(string test_name);
    int errors = 0;
    golden_matmul();

    // Pulse clear for one cycle to zero every accumulator.
    @(negedge clk); clear = 1; en = 0;
    @(negedge clk); clear = 0;

    // Feed T_FEED skewed cycles. Driving on the negedge keeps the values
    // stable at each posedge.
    // The per-lane guard applies the same window as the RTL: inject a real
    // element only while 0 <= t-lane < N, otherwise inject zero.
    for (int t = 0; t < T_FEED; t++) begin
      for (int lane = 0; lane < N; lane++) begin
        a_feed[lane] = (t >= lane && t - lane < N) ? A[lane][t-lane] : '0;
        b_feed[lane] = (t >= lane && t - lane < N) ? B[t-lane][lane] : '0;
      end
      en = 1;
      @(negedge clk);
    end
    // Drop enable and clear the feeds so no data stays in the wavefront.
    en = 0;
    foreach (a_feed[lane]) a_feed[lane] = '0;
    foreach (b_feed[lane]) b_feed[lane] = '0;
    @(negedge clk);

    // Check every accumulator.
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        if (C[i][j] !== expected[i][j]) begin
          errors++;
          $display("   mismatch C[%0d][%0d]: got %0d, expected %0d",
                   i, j, $signed(C[i][j]), expected[i][j]);
        end

    // On pass, also report throughput (MACs per feed cycle).
    if (errors == 0) begin
      $display("PASS [%s]  (%0d feed cycles for %0d MACs -> %.1f MACs/cycle avg)",
               test_name, T_FEED, N*N*N, real'(N*N*N)/T_FEED);
      n_pass++;
    end else begin
      $display("FAIL [%s]: %0d mismatching elements", test_name, errors);
      n_fail++;
    end
  endtask

  // Stimulus
  initial begin
    $dumpfile("tb_systolic_array.vcd");
    $dumpvars(0, tb_systolic_array);

    // Idle controls, zero the feeds, and apply reset before the first test.
    clear = 0; en = 0; rst_n = 0;
    foreach (a_feed[i]) a_feed[i] = '0;
    foreach (b_feed[i]) b_feed[i] = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // Test 1: identity matrix B, so C must equal A. This isolates dataflow and
    // skew timing.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'(i*N + j + 1);
    foreach (B[i, j]) B[i][j] = (i == j) ? DATA_WIDTH'(1) : '0;
    run_and_check("identity");

    // Test 2: small positives.
    foreach (A[i, j]) A[i][j] = DATA_WIDTH'(i + 2);
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'(j + 1);
    run_and_check("small_positive");

    // Test 3: negatives.
    foreach (A[i, j]) A[i][j] = -DATA_WIDTH'(j + 1);
    foreach (B[i, j]) B[i][j] = (i % 2 == 0) ? -DATA_WIDTH'(7) : DATA_WIDTH'(4);
    run_and_check("negatives");

    // Test 4: zeros.
    foreach (A[i, j]) A[i][j] = '0;
    foreach (B[i, j]) B[i][j] = DATA_WIDTH'(99);
    run_and_check("zeros");

    // Test 5: random limited-magnitude INT8 with three seeds back to back,
    // which also confirms that 'clear' resets the array state between runs.
    repeat (3) begin
      foreach (A[i, j]) A[i][j] = DATA_WIDTH'($urandom_range(0, 60)) - DATA_WIDTH'(30);
      foreach (B[i, j]) B[i][j] = DATA_WIDTH'($urandom_range(0, 60)) - DATA_WIDTH'(30);
      run_and_check("random_limited");
    end

    $display("\n==== tb_systolic_array: %0d passed, %0d failed ====", n_pass, n_fail);
    if (n_fail == 0) $display("ALL TESTS PASS");
    else             $display("SOME TESTS FAILED");
    $finish;
  end

endmodule : tb_systolic_array
