// =============================================================================
// hw_top.sv - physical-board demonstration wrapper for the accelerator
//-----------------------------------------------------------------------------
// Purpose:
//   Run the accelerator on a real Cyclone 10 GX development board using a
//   small number of real pins (one clock, two buttons, one switch, three LEDs).
//   The wide matrix interface stays internal: the test matrices A and B are
//   compiled in as constants, the core computes C, and on-chip logic compares
//   C against the precomputed answer and drives a pass indicator. 
//
// Real pins (assign from board documentation, see hw_top_pins_template.tcl):
//   clk            board oscillator input 
//   rst_n          pushbutton, active low 
//   btn_start      pushbutton 
//   sw_sel         DIP switch (0 = sequential, 1 = systolic)
//   led_pass       on when C equals the expected result
//   led_done       on when a run has completed
//   led_heartbeat  blinks at ~1 Hz to confirm the board is configured
//                  and clocked
//
// Button and LED polarity:
//   Many pushbuttons are active low (pressed reads as 0) with
//   hardware pull-ups, and this code assumes that. If the board differs,
//   change BTN_ACTIVE_LOW. LED polarity is handled the same way via
//   LED_ACTIVE_LOW.
// =============================================================================

module hw_top #(
  // Heartbeat divider bit: at 50 to 100 MHz, bit 25 toggles at roughly 1 to 3 Hz.
  parameter int HEARTBEAT_BIT = 25,
  // Debounce counter width: 2^DEBOUNCE_BITS stable clocks are required.
  // 2^20 / 50 MHz is about 21 ms.
  parameter int DEBOUNCE_BITS = 20,
  parameter bit BTN_ACTIVE_LOW = 1'b1,   // pressed reads as 0
  parameter bit LED_ACTIVE_LOW = 1'b0    // 0 lights the LED
) (
  input  logic clk,
  input  logic rst_n,         // raw asynchronous pushbutton (active low)
  input  logic btn_start,     // raw asynchronous pushbutton
  input  logic sw_sel,        // engine select: 0 sequential, 1 systolic
  output logic led_pass,      // lit on a bit-exact match against C_EXPECTED
  output logic led_done,      // lit once a run has completed and been checked
  output logic led_heartbeat  // free-running blink to confirm the clock is alive
);
 
  // -------------------------------------------------------------------------
  // A and B use mixed signs to exercise signed arithmetic. The reference 
  // product C = A * B (decimal, row-major) is:
  //      -2    17    -6     1
  //      27   -13    12    27
  //       4    -5     0    -5
  //       7    27   -22    25
  // -------------------------------------------------------------------------
  // Packed storage of A and B, row-major, 8 bits per element. These
  // are unpacked into a_arr/b_arr below for the core's array ports.
  // Setting the operands as constants lets the on-chip test run with no
  // external data path. C_EXPECTED is the golden value the FSM compares against.
  localparam logic [127:0] A_PACKED = {8'sd1, 8'sd6, 8'sd2, -8'sd3, -8'sd4, 8'sd1, 8'sd3, 8'sd0, 8'sd5, -8'sd2, 8'sd4, 8'sd1, 8'sd0, 8'sd3, -8'sd1, 8'sd2};
  localparam logic [127:0] B_PACKED = {8'sd4, 8'sd0, 8'sd1, 8'sd2, 8'sd2, -8'sd3, 8'sd5, 8'sd0, 8'sd3, 8'sd1, -8'sd2, 8'sd4, -8'sd1, 8'sd2, 8'sd0, 8'sd1};
  // Golden result, 32-bit signed two's complement per cell, row-major. Negative
  // cells appear as sign-extended hex, for example -22 is 32'hFFFFFFEA.
  localparam logic [511:0] C_EXPECTED = {32'h00000019, 32'hFFFFFFEA, 32'h0000001B, 32'h00000007, 32'hFFFFFFFB, 32'h00000000, 32'hFFFFFFFB, 32'h00000004, 32'h0000001B, 32'h0000000C, 32'hFFFFFFF3, 32'h0000001B, 32'h00000001, 32'hFFFFFFFA, 32'h00000011, 32'hFFFFFFFE};
 
  // Unpack the packed buses into the core's [4][4] signed array ports.
  // Pure compile time wiring. The same row-major slicing used everywhere else
  // in the design applies here, element (gi,gj) at bit (gi*4+gj)*8.
  logic signed [7:0] a_arr [4][4];
  logic signed [7:0] b_arr [4][4];
  genvar gi, gj;
  generate
    for (gi = 0; gi < 4; gi++) begin : g_row
      for (gj = 0; gj < 4; gj++) begin : g_col
        assign a_arr[gi][gj] = A_PACKED[(gi*4+gj)*8 +: 8];
        assign b_arr[gi][gj] = B_PACKED[(gi*4+gj)*8 +: 8];
      end
    end
  endgenerate
 
  // -------------------------------------------------------------------------
  // Input conditioning: synchronize asynchronous inputs, normalize polarity,
  // and debounce the start button.
  // -------------------------------------------------------------------------
  // Two-flop synchronizers reduce risk on asynchronous inputs.
  // Each raw pin passes through two flops before use.
  logic [1:0] rst_sync, start_sync, sw_sync;
  always_ff @(posedge clk) begin
    rst_sync   <= {rst_sync[0],   rst_n};      // shift the raw pin into bit 0, settled value in bit 1
    start_sync <= {start_sync[0], btn_start};
    sw_sync    <= {sw_sync[0],    sw_sel};
  end
  // Normalize to an active-low internal reset and a clean button level.
  logic rst_n_clean;
  logic start_level;
  logic sel_systolic;
  assign rst_n_clean  = rst_sync[1];                                    // already active low, synchronized
  assign start_level  = BTN_ACTIVE_LOW ? ~start_sync[1] : start_sync[1]; // 1 = pressed
  assign sel_systolic = sw_sync[1];                                     // engine select, synchronized
 
  // Debounce the start button and produce a single cycle pulse per press.
  // The counter only advances while the live input disagrees with the accepted
  // stable value. It resets on any agreement, so the level must hold steady for
  // a full 2^DEBOUNCE_BITS window before it is accepted.
  logic [DEBOUNCE_BITS-1:0] db_cnt;
  logic start_stable, start_stable_d;
  always_ff @(posedge clk or negedge rst_n_clean) begin
    if (!rst_n_clean) begin
      db_cnt <= '0; start_stable <= 1'b0; start_stable_d <= 1'b0;
    end else begin
      if (start_level == start_stable) begin
        db_cnt <= '0;                            // input matches stable value: reset timer
      end else begin
        db_cnt <= db_cnt + 1'b1;                 // input differs: count toward acceptance
        if (&db_cnt) start_stable <= start_level; // stable long enough: accept new level
      end
      start_stable_d <= start_stable;            // one-cycle delayed copy for edge detection
    end
  end
  // Rising edge of the debounced level. High for exactly one clock per press,
  // which is what the control FSM consumes as its trigger.
  wire start_pressed = start_stable & ~start_stable_d; // rising edge: one press
 
  // -------------------------------------------------------------------------
  // Heartbeat: confirms the clock and configuration are active before any press.
  // -------------------------------------------------------------------------
  // Free-running counter. A high-order bit is tapped as the blink source, so a
  // steady blink proves the clock is running and the design is configured.
  logic [HEARTBEAT_BIT:0] hb_cnt;
  always_ff @(posedge clk or negedge rst_n_clean) begin
    if (!rst_n_clean) hb_cnt <= '0;
    else              hb_cnt <= hb_cnt + 1'b1;
  end
 
  // -------------------------------------------------------------------------
  // Accelerator core (matmul_top: both engines and the runtime select).
  // -------------------------------------------------------------------------
  // sel_systolic picks which engine runs. The conditioned operands and start
  // pulse feed in here, and the flat result comes back on core_c_flat.
  logic core_start, core_busy, core_done;
  logic [511:0] core_c_flat;
 
  matmul_top #(.DATA_WIDTH(8), .ACC_WIDTH(32), .MATRIX_SIZE(4)) u_core (
    .clk          (clk),
    .rst_n        (rst_n_clean),
    .start        (core_start),
    .sel_systolic (sel_systolic),
    .a_in         (a_arr),
    .b_in         (b_arr),
    .c_flat       (core_c_flat),
    .busy         (core_busy),
    .done         (core_done)
  );
 
  // -------------------------------------------------------------------------
  // Control FSM: on a press, pulse start, wait for done, compare, latch result.
  // -------------------------------------------------------------------------
  // S_IDLE waits for a press. S_RUN waits for the core to finish. S_CHECK
  // compares against the golden value and latches the outcome. S_HOLD displays
  // the result until the next press rearms the test.
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_CHECK, S_HOLD} state_t;
  state_t state;
  logic result_pass, result_done;
 
  always_ff @(posedge clk or negedge rst_n_clean) begin
    if (!rst_n_clean) begin
      state <= S_IDLE; core_start <= 1'b0;
      result_pass <= 1'b0; result_done <= 1'b0;
    end else begin
      core_start <= 1'b0;                  // default: start is a one-cycle pulse
      case (state)
        S_IDLE:  if (start_pressed) begin
                   core_start <= 1'b1;       // begin one multiplication
                   result_done <= 1'b0;      // clear the previous run's status
                   state <= S_RUN;
                 end
        S_RUN:   if (core_done) state <= S_CHECK;    // wait for the core
        S_CHECK: begin
                   result_pass <= (core_c_flat == C_EXPECTED); // bit-exact compare
                   result_done <= 1'b1;                        // mark this run as checked
                   state <= S_HOLD;
                 end
        S_HOLD:  if (start_pressed) state <= S_IDLE; // next press re-arms
        default: state <= S_IDLE;                    // recover from any illegal state
      endcase
    end
  end
 
  // -------------------------------------------------------------------------
  // LED outputs with board polarity applied.
  // -------------------------------------------------------------------------
  // Raw active-high intent. The LED_ACTIVE_LOW parameter inverts each line if
  // the board lights its LEDs on a logic 0, keeping the FSM logic polarity agnostic.
  wire pass_raw      = result_pass;
  wire done_raw      = result_done;
  wire heartbeat_raw = hb_cnt[HEARTBEAT_BIT];
 
  assign led_pass      = LED_ACTIVE_LOW ? ~pass_raw      : pass_raw;
  assign led_done      = LED_ACTIVE_LOW ? ~done_raw      : done_raw;
  assign led_heartbeat = LED_ACTIVE_LOW ? ~heartbeat_raw : heartbeat_raw;
 
endmodule
