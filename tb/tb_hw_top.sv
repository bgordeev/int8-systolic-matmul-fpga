// =============================================================================
// tb_hw_top.sv - simulate the board wrapper before programming hardware
//-----------------------------------------------------------------------------
// Drives the clock and buttons, presses start, and confirms that led_pass
// asserts (correct result) and led_done asserts. The debounce and heartbeat
// parameters are shortened so the test runs quickly in simulation.
//
// Run (Icarus):  iverilog -g2012 -o sim_hw rtl/*.sv tb/tb_hw_top.sv && vvp sim_hw
// Run (Questa):  vlog -sv rtl/*.sv tb/tb_hw_top.sv ; vsim -c tb_hw_top -do "run -all; quit"
// =============================================================================
`timescale 1ns/1ps
module tb_hw_top;
 
  logic clk = 0;
  logic rst_n = 0;
  logic btn_start = 1;   // active-low button: 1 = not pressed
  logic sw_sel = 1;      // 1 = systolic engine
  logic led_pass, led_done, led_heartbeat;
 
  // Short debounce and heartbeat keep the simulation fast. Button active low,
  // LED active high.
  // The real board uses larger counters. Shrinking them lets the debounce
  // window and heartbeat resolve in a few cycles instead of millions.
  hw_top #(
    .HEARTBEAT_BIT (4),
    .DEBOUNCE_BITS (4),
    .BTN_ACTIVE_LOW(1'b1),
    .LED_ACTIVE_LOW(1'b0)
  ) dut (
    .clk(clk), .rst_n(rst_n), .btn_start(btn_start), .sw_sel(sw_sel),
    .led_pass(led_pass), .led_done(led_done), .led_heartbeat(led_heartbeat)
  );
 
  always #5 clk = ~clk;  // 100 MHz
 
  // Press the active-low button: drive low, hold past the debounce window,
  // then release.
  // The 64-cycle holds exceed the shortened debounce window, so
  // each press and release registers as one debounced event.
  task press_button;
    int i;
    begin
      btn_start = 1'b0;                       // press
      for (i = 0; i < 64; i++) @(posedge clk);
      btn_start = 1'b1;                       // release
      for (i = 0; i < 64; i++) @(posedge clk);
    end
  endtask
 
  initial begin
    // Reset
    // Hold reset low, then release.
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (8) @(posedge clk);
 
    // Test 1: systolic engine
    // Select the systolic engine, press start, and wait for the run to finish
    // before sampling the LEDs.
    sw_sel = 1'b1;
    press_button();
    repeat (40) @(posedge clk);
    // led_done must be high once the FSM has checked a result.
    if (led_done !== 1'b1) begin
      $display("FAIL: led_done not asserted after systolic run"); $finish;
    end
    // led_pass high means the result matched the golden value in hw_top.
    if (led_pass !== 1'b1) begin
      $display("FAIL: led_pass low, systolic result mismatch"); $finish;
    end
    $display("PASS: systolic run - led_done=1, led_pass=1");
 
    // Test 2: sequential engine
    // After a run the FSM sits in S_HOLD, so one press re-arms it before the
    // next test switches engines.
    press_button();           // in S_HOLD this re-arms back to S_IDLE
    repeat (10) @(posedge clk);
    sw_sel = 1'b0;
    press_button();
    repeat (120) @(posedge clk);  // the sequential engine takes longer (81 cycles)
    // Only led_pass is rechecked here. led_done was already tested in Test 1.
    if (led_pass !== 1'b1) begin
      $display("FAIL: led_pass low, sequential result mismatch"); $finish;
    end
    $display("PASS: sequential run - led_pass=1");
 
    $display("ALL HW_TOP TESTS PASS");
    $finish;
  end
 
  // Timeout
  initial begin
    #200000;
    $display("FAIL: timeout"); $finish;
  end
 
endmodule
