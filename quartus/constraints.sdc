# =============================================================================
# constraints.sdc - timing constraints for the INT8 matmul accelerator
# =============================================================================

# 100 MHz target on the top-level clock input.
create_clock -name clk -period 10.000 [get_ports clk]

# Let Quartus compute realistic clock uncertainty (jitter etc.) 
derive_clock_uncertainty

# Virtual-pin I/O paths are internal. 

