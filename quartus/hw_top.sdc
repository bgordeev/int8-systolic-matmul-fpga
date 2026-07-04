# =============================================================================
# hw_top.sdc - Timing constraints for the physical-board demo (hw_top).
#
# Set the clock period to match your board's oscillator that feeds
# the `clk` pin. Common reference clocks are 50 MHz (20 ns) or 100 MHz (10 ns).
#
# =============================================================================

# Example for a 50 MHz oscillator (period = 20 ns):
create_clock -name clk -period 20.000 [get_ports clk]

derive_clock_uncertainty

# The pushbuttons and switch are asynchronous to clk and are synchronized
# inside hw_top (2-flop synchronizers), so they are excluded from timing analysis.
set_false_path -from [get_ports {rst_n btn_start sw_sel}] -to [all_registers]

# LEDs.
set_false_path -from * -to [get_ports {led_pass led_done led_heartbeat}]
